#encoding: UTF-8
require 'spree_core'
require 'synergy_1c7_connector_hooks'

module Synergy1c7Connector
    class Engine < Rails::Engine

        config.autoload_paths += %W(#{config.root}/lib)

        def self.activate
            Dir.glob(File.join(File.dirname(__FILE__), "../app/**/*_decorator*.rb")) do |c|
                Rails.env.production? ? require(c) : load(c)
            end
        end

        config.to_prepare &method(:activate).to_proc
    end

    class Connection
        def initialize
            @xml_string = ""
        end
        def parse_xml
            # If file present
            import_path = "#{Rails.root}/../../shared/webdata/import.xml"
            offers_path = "#{Rails.root}/../../shared/webdata/offers.xml"
            xml = Nokogiri::XML.parse(File.read(import_path))
            offers_xml = Nokogiri::XML.parse(File.read(offers_path))

            # Parsing
            taxonomy = Taxonomy.find_or_create_by_name(xml.css("Классификатор Группы Группа Наименование").first.text)
            taxonomy.taxons.first.update_attributes(:name => xml.css("Классификатор Группы Группа Наименование").first.text, :code_1c => xml.css("Классификатор Группы Группа Ид").first.text)
            view_taxonomy = Taxonomy.find_or_create_by_name("Каталог")
            view_taxonomy.update_attributes(:show_on_homepage => true)
            parse_groups_from_import_xml(xml.css("Классификатор Группы Группа Группы Группа"), taxonomy.root)
            create_properties(xml.css("Свойства Свойство"))
            parse_products(xml.css("Товар"), get_property_values(xml.css("Справочник")))
            parse_products_offers_xml(offers_xml.css("Предложение"))
            set_product_price
            create_similar_taxons(view_taxonomy.root, taxonomy.root)
        end

        def discharge(order)
            order.discharge = true
            order.save
            xml
            create_xml_discharge(order)
        end


        def tag(tag, attrs={}, &block)
            @xml_string << "<#{tag}"
            text = attrs.delete(:text)
            @xml_string << " " if not attrs.empty?
            attrs.each_pair do |key, value|
                @xml_string << "#{key.to_s}=\"#{value.to_s}\""
                @xml_string << " " if key != attrs.keys.last
            end
            @xml_string << ">"
            if block_given?
                block.arity < 1 ? self.instance_eval(&block) : block.call(self)
            end
            @xml_string << text.to_s.gsub(/[&"'<>]/) {|match| REPLACEMENTS[match]} if text
            @xml_string << "</#{tag}>"
        end


        private

        def xml
            @xml_string << "<?xml version=\"1.0\" encoding=\"windows-1251\"?>"
        end


        def get_property_values(xml_values)
            property_values = Hash.new
            xml_values.each do |xml_value|
                property_values["#{xml_value.css('ИдЗначения').text}"] = "#{xml_value.css('Значение').text}"
            end
            return property_values
        end

        def create_properties(xml_properties)
            xml_properties.each do |xml_property|
                property = Property.find_or_initialize_by_code_1c(xml_property.css("Ид").first.text)
                property.name = xml_property.css("Наименование").first.text
                property.presentation = property.name
                property.save
            end
        end

        def create_similar_taxons(taxon, taxon_copy_from)
            taxon_copy_from.children.each do |taxon_copy_from_child|
                name = taxon_copy_from_child.name
                if name.first.to_i != 0
                    if name.split.second == "PE"
                        name = name.split[2..10].join(" ")
                    else
                        name = name.split[1..10].join(" ")
                    end
                end
                new_taxon = Taxon.find_or_initialize_by_name_and_parent_id(name, taxon.id)
                new_taxon.parent_id = taxon.id
                new_taxon.taxonomy_id = taxon.taxonomy_id
                taxon_copy_from_child.products.each do |product|
                    if new_taxon.products.where(:id => product.id).blank?
                        new_taxon.products << product
                    end
                end
                new_taxon.save
                create_similar_taxons(new_taxon, taxon_copy_from_child)
            end
        end

        def create_xml_discharge(order)
            tag "КоммерческаяИнформация", { "ВерсияСхемы" => "2.03", "ДатаФормирования" => Time.now.to_s.split(" ").first.tr(".","-") } do
                 tag "Документ" do
                    tag "Номер", :text => order.id
                    tag "Дата", :text => order.created_at
                    tag "ХозОперация", :text => "Заказ товара"
                    tag "Роль", :text => "Администратор"
                    tag "Валюта", :text => "руб"
                    tag "Курс", :text => "1"
                    tag "Сумма", :text => order.total
                    tag "Контрагенты" do
                        tag "Контрагент" do
                            tag "Наименование", :text => order.user.full_name
                            tag "Роль", :text => "Покупатель"
                            tag "ПолноеНаименование", :text => order.ship_address.lastname + order.ship_address.firstname + order.ship_address.secondname
                            tag "Фамилия", :text => order.ship_address.lastname
                            tag "Имя", :text => order.ship_address.firstname
                            tag "АдресРегистрации" do
                                tag "Представление", :text => order.ship_address.address1
                                tag "АдресноеПоле" do
                                    tag "Тип", :text => "Почтовый индекс"
                                    tag "Значение", :text => order.ship_address.zipcode
                                end
                            end
                        end
                    end
                    tag "Время", :text => order.created_at.hour.to_s + ":" + order.created_at.min.to_s + ":" + order.created_at.sec.to_s
                    tag "Товары" do
                        order.line_items.each do |line_item|
                            tag "Товар" do
                                tag "Ид", :text => line_item.product.code_1c
                                tag "Группы", :text => line_item.product.taxons.last.code_1c
                                tag "Наименование", :text => line_item.product.name
                                tag "БазоваяЕдиница", {"Код" => "796", "НаименованиеПолное" => "Штука", "МеждународноеСокращение" => "PCE", :text => "шт" }
                                tag "ЦенаЗаЕдиницу", :text => line_item.product.price
                                tag "Количество", :text => line_item.quantity
                                tag "Сумма", :text => (line_item.quantity.to_f * line_item.product.price.to_f).to_s
                                tag "ЗначенияРеквизитов" do
                                    tag "ЗначениеРеквизита" do
                                        tag "Наименование", :text => "ВидНоменклатуры"
                                        tag "Значение", :text => "Бельё и колготки"
                                    end
                                    tag "ЗначениеРеквизита" do
                                        tag "Наименование", :text => "ТипНоменклатуры"
                                        tag "Значение", :text => "Товар"
                                    end
                                end
                                tag "ХарактеристикиТовара" do
                                    line_item.variant.option_values.each do |value|
                                        tag "ХарактеристикаТовара" do
                                            tag "Наименование", :text => value.option_type.name
                                            tag "Значение", :text => value.name
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            #File.open("#{Rails.root}/../../shared/spree_discharge/spree_1c.xml", 'w') { |f| f.write(xml_file) }

        end

        def set_product_price
            Product.all.each do |product|
                if not product.variants.blank?
                    price = 0
                    cost_price = 0
                    code_1c = ""
                    product.variants.each do |var|
                        price = var.price if var.price.to_i != 0
                        cost_price = var.cost_price if var.cost_price.to_i != 0
                    end
                    product.price = price
                    product.cost_price = cost_price
                    product.save
                end
            end
        end

        def parse_groups_from_import_xml(groups, taxon)
            groups.each do |group|
                new_taxon = Taxon.find_or_create_by_code_1c(group.css("Ид").first.text)
                if new_taxon.new_record?
                    new_taxon.update_attributes(:name => group.css("Наименование").first.text, :taxonomy_id => taxon.taxonomy_id, :parent_id => taxon.id)
                    parse_groups_from_import_xml(group.css("Группы Группа"), new_taxon)
                end
            end
        end

        def parse_products_offers_xml(products)
            products.each do |xml_product|
                product = Product.find_by_code_1c(xml_product.css("Ид").text.split('#').first)

                variant = Variant.find_or_initialize_by_code_1c(xml_product.css("Ид").text)
                variant.product_id = product.id
                prices = Array.new
                prices << xml_product.css("ЦенаЗаЕдиницу").first.text.to_i
                prices << xml_product.css("ЦенаЗаЕдиницу").last.text.to_i
                prices.sort!
                variant.cost_price = prices.first
                variant.price = prices.last
                variant.count_on_hand = xml_product.css("Количество").text if not xml_product.css("Количество").text.blank?
                if variant.new_record?
                    xml_product.css("ХарактеристикаТовара").each do |option|
                        if ProductOptionType.where(:product_id => product.id, :option_type_id => OptionType.find_by_name(option.css("Наименование").text).id).blank?
                            product_option_type = ProductOptionType.new(:product => product, :option_type => OptionType.find_by_name(option.css("Наименование").text))
                            product_option_type.save
                        end
                        if OptionValue.find_by_name_and_option_type_id(option.css("Значение").text, OptionType.find_by_name(option.css("Наименование").text).id)
                            option_value = OptionValue.find_by_name_and_option_type_id(option.css("Значение").text, OptionType.find_by_name(option.css("Наименование").text).id)
                        else
                            option_value = OptionValue.create(:option_type_id => OptionType.find_by_name(option.css("Наименование").text).id, :name => option.css("Значение").text,:presentation => option.css("Значение").text)
                        end
                        variant.option_values << option_value
                    end
                end
                variant.save
            end
        end

        def parse_products(products, property_values)
            products.each do |xml_product|
                product = Product.find_or_initialize_by_code_1c(xml_product.css("Ид").first.text)
                if product.new_record?
                    product.sku = xml_product.css("Артикул").first.text
                    product.name = product.sku + " " + xml_product.css("Наименование").first.text
                    xml_product.css("ЗначенияСвойства").each do |xml_property|
                        property = product.product_properties.find_or_initialize_by_product_id_and_property_id(product.id, Property.find_by_code_1c(xml_property.css("Ид").text).id)
                        value = xml_property.css("Значение").text
                        property.value = value if not value.blank?
                        if property.value.length == 36
                            property.value = property_values.values_at(property.value).first
                        end
                        property.save
                    end
                    product.price = 0
                    images = xml_product.css("Картинка")
                    images.each do |image|
                        new_image = product.images.find_or_initialize_by_attachment_file_name(image.text.split('/').last, :attachment => File.open("#{Rails.root}/../../shared/webdata/" + image.text))
                        new_image.save
                    end
                    description = xml_product.css("Описание").first
                    if !description.blank?
                        product.description = description.text
                    end
                    product.available_on = Time.now
                    xml_product.css("Группы Ид").each do |xml_taxon|
                        product.taxons << Taxon.where(:code_1c => xml_taxon.text)
                    end
                    product.save!
                else
                    product.sku = xml_product.css("Артикул").first.text
                    product.name = product.sku + " " + xml_product.css("Наименование").first.text
                    xml_product.css("ЗначенияСвойства").each do |xml_property|
                        property = product.product_properties.find_or_initialize_by_product_id_and_property_id(product.id, Property.find_by_code_1c(xml_property.css("Ид").text).id)
                        value = xml_property.css("Значение").text
                        property.value = value
                        if property.value.length == 36
                            property.value = property_values.values_at(property.value).first
                        end
                        property.save if not value.blank?
                    end
                    images = xml_product.css("Картинка")
                    images.each do |image|
                        new_image = product.images.find_or_initialize_by_attachment_file_name(image.text.split('/').last, :attachment => File.open("#{Rails.root}/../../shared/webdata/" + image.text))
                        new_image.save
                    end

                    description = xml_product.css("Описание").first
                    if !description.blank?
                        product.description = description.text
                    end
                    # Update taxon only have non-empty code_1c attribute
                    xml_product.css("Группы Ид").each do |xml_taxon|
                        product.taxons << Taxon.where(:code_1c => xml_taxon.text)
                    end
                    product.save
                end
            end
        end

    end
end
