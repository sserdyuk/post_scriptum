class ActionController::IntegrationTest

  def assert_select_fields(fields)
    fields.each do |field|
      assert_select '*[name=?]', field, {}, "Field '#{field}' is missing."
    end
  end

  def assert_select_model_fields(model, *fields)
    matches = assert_select 'input[name=?],select[name=?],textarea[name=?]', /^#{model}\[.+?\]$/, /^#{model}\[.+?\]$/, /^#{model}\[.+?\]$/
    matched_fields = matches.collect{|match| match['name']}.uniq
#    assert_equal fields.size, matched_fields.size, 'Model field count does not match'
    fields = fields.collect{|field| field.to_s.split('/').collect{|el| "[#{el}]"}}.collect{|field| "#{model}#{field}"}
    missing_fields = fields- matched_fields
    assert missing_fields.empty?, "Expected fields are missing: #{missing_fields.join(', ')}"
    extra_fields = matched_fields- fields
    assert extra_fields.empty?, "Unexpected fields are found: #{extra_fields.join(', ')}"
#    fields.each do |field|
#      assert_select 'input[name=?],select[name=?],textarea[name=?]', "#{model}[#{field}]", "#{model}[#{field}]", "#{model}[#{field}]", {}, "Field '#{field}' is missing."
#    end
  end

  def assert_select_errors(count, *field_names)
    if count && count != :none
      assert_select 'div.error-messages', {}, 'Error messages are expected but not shown '
      assert_select 'div.error-messages ul li', count, 'Error message count does not match expected'
    else
      assert_select 'div.error-messages', 0, 'Error messages are shown unexpectedly'
    end
    field_names.each do |field_name|
      assert_select 'form div.field-with-errors *[name=?]', field_name, {}, "Field #{field_name} is not shown with errors as expected"
    end
  end

  def assert_hobo_record(record)
    assert_select '*[hobo-model-id=?]', "#{record.class.name.underscore}_#{record.id}"
  end

  def assert_no_hobo_record(record)
    assert_select '*[hobo-model-id=?]', "#{record.class.name.underscore}_#{record.id}", 0
  end

  def assert_changes_to(expression, value, &block)
    assert_not_equal value, eval(expression, block.send(:binding))
    yield if block_given?
    assert_equal value, eval(expression, block.send(:binding))
  end

  def assert_stays(expression, &block)
    value = eval(expression, block.send(:binding))
    yield if block_given?
    assert_equal value, eval(expression, block.send(:binding))
  end

  def assert_deleted(klass, condition, &block)
    assert klass.exists?(condition)
    yield if block_given?
    assert !klass.exists?(condition)
  end

  def image_upload
    ActionController::TestUploadedFile.new("#{RAILS_ROOT}/test/fixtures/files/image.png", 'image/png', true)
  end

  def document_upload
    ActionController::TestUploadedFile.new("#{RAILS_ROOT}/test/fixtures/files/document.txt", 'text/plain', true)
  end

  def save_and_open_page
    saved_page_dir = File.join(RAILS_ROOT, 'tmp')
    return unless File.exist?(saved_page_dir)

    filename = "#{saved_page_dir}/webrat-#{Time.now.to_i}.html"

    File.open(filename, "w") do |f|
      f.write rewrite_css_and_image_references(response.body)
    end

    open_in_browser(filename)
  end unless method_defined? :save_and_open_page

  alias_method :firefox, :save_and_open_page

  def open_in_browser(path) #:nodoc
    `firefox #{path}`
  end

  def rewrite_css_and_image_references(response_html) 
    doc_root = '"../public'
    return response_html unless doc_root
    response_html.gsub(/"\/(stylesheets|images|hobothemes|javascripts)/, doc_root + '/\1')
  end unless method_defined? :rewrite_css_and_image_references

end

class ActiveRecord::Base
  def [](*attr_names)
    if attr_names.size <= 1
      read_attribute(attr_names.first)
    else
      attr_names.map_hash{|attr| read_attribute(attr)}
    end
  end
end
