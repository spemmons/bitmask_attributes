module BitmaskAttributes
  class Definition
    attr_reader :attribute, :values, :allow_null, :extension
    
    def initialize(attribute, values=[],allow_null = true, &extension)
      @attribute = attribute
      @values = values
      @extension = extension
      @allow_null = allow_null
    end
    
    def install_on(model)
      validate_for model
      generate_bitmasks_on model
      override model
      create_convenience_class_method_on model
      create_convenience_instance_methods_on model
      create_scopes_on model
      create_attribute_methods_on model
    end

    private

      def validate_for(model)
        # The model cannot be validated if it is preloaded and the attribute/column is not in the
        # database (the migration has not been run) or table doesn't exist. This usually
        # occurs in the 'test' and 'production' environment or during migration.
        return if defined?(Rails) && Rails.configuration.cache_classes || !model.table_exists?

        unless model.columns.detect { |col| col.name == attribute.to_s }
          Rails.logger.warn "WARNING: `#{attribute}' is not an attribute of `#{model}'. But, it's ok if it happens during migrations and your \"bitmasked\" attribute is still not created."
        end
      end
    
      def generate_bitmasks_on(model)
        model.bitmasks[attribute] = HashWithIndifferentAccess.new.tap do |mapping|
          values.each_with_index do |value, index|
            mapping[value] = 0b1 << index
          end
        end
      end
    
      def override(model)
        override_getter_on(model)
        override_setter_on(model)
      end
    
      def override_getter_on(model)
        model.class_eval %(
          def #{attribute}
            @#{attribute} ||= BitmaskAttributes::ValueProxy.new(self, :#{attribute}, &self.class.bitmask_definitions[:#{attribute}].extension)
          end
        )
      end
    
      def override_setter_on(model)
        model.class_eval %(
          def #{attribute}=(raw_value)
            values = raw_value.kind_of?(Array) ? raw_value : [raw_value]
            self.#{attribute}.replace(values.reject(&:blank?))
          end
        )
      end
    
      # Returns the defined values as an Array.
      def create_attribute_methods_on(model)
        model.class_eval %(
          def self.values_for_#{attribute}      # def self.values_for_numbers
            #{values}                           #   [:one, :two, :three]
          end                                   # end
        )
      end
    
      def create_convenience_class_method_on(model)
        model.class_eval %(
          def self.bitmask_for_#{attribute}(*values)
            values.inject(0) do |bitmask, value|
              unless (bit = bitmasks[:#{attribute}][value])
                raise ArgumentError, "Unsupported value for #{attribute}: \#{value.inspect}"
              end
              bitmask | bit
            end
          end
        )
      end

      def create_convenience_instance_methods_on(model)
        values.each do |value|
          model.class_eval %(
            def #{attribute}_for_#{value}?                  
              self.#{attribute}?(:#{value})
            end
          )
        end
        model.class_eval %(
          def #{attribute}?(*values)
            if !values.blank?
              values.all? do |value|
                self.#{attribute}.include?(value)
              end
            else
              self.#{attribute}.present?
            end
          end
        )
      end
    
      def create_scopes_on(model)
        if allow_null
          or_is_null_condition = " OR #{attribute} IS NULL"
          or_is_not_null_condition = " OR #{attribute} IS NOT NULL"
        end

        model.class_eval %(
          scope :with_#{attribute},
            proc { |*values|
              if values.blank?
                where('#{attribute} > 0')
              else
                sets = values.map do |value|
                  mask = #{model}.bitmask_for_#{attribute}(value)
                  "#{attribute} & \#{mask} <> 0"
                end
                where(sets.join(' AND '))
              end
            }
          scope :without_#{attribute}, 
            proc { |*values|
              if values.blank?
                no_#{attribute}
              else
                where("#{attribute} & ? = 0#{or_is_null_condition}", #{model}.bitmask_for_#{attribute}(*values))
              end
            }

          scope :with_exact_#{attribute},
            proc { | *values|
              if values.blank?
                no_#{attribute}
              else
                where("#{attribute} = ?", #{model}.bitmask_for_#{attribute}(*values))
              end
            }
          
          scope :no_#{attribute}, proc { where("#{attribute} = 0#{or_is_null_condition}") }

          scope :with_any_#{attribute},
            proc { |*values|
              if values.blank?
                where('#{attribute} > 0')
              else
                where("#{attribute} & ? <> 0", #{model}.bitmask_for_#{attribute}(*values))
              end
            }
        )
        values.each do |value|
          model.class_eval %(
            scope :#{attribute}_for_#{value},
                  proc { where('#{attribute} & ? <> 0', #{model}.bitmask_for_#{attribute}(:#{value})) }
          )
        end      
      end
  end
end
