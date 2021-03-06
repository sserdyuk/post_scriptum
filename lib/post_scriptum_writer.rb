# Copyright (c) 2010 Red Leaf Software LLC
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# How to use:
#
# Add a filter hookup at the top of the ApplicationController like:
#
## class ApplicationController < ActionController::Base
##   prepend_around_filter PostScriptumWriter if ENV['RAILS_ENV'] == 'development'
#
# The results are written to test_ps.rb file in the project top directory.
#
#

require 'nokogiri'
require 'action_controller/test_process'

class PostScriptumWriter

  @@last_status = ''
  @@last_request_uri = ''
  @@last_request_ajax = nil
  @@last_created = {}
  @@models = nil

  def self.filter(this_controller, &block)

    @@models ||= begin
      Dir.glob("#{RAILS_ROOT}/app/models/**/*.rb").each{|name| require name}
      klasses = ActiveRecord::Base.send(:subclasses)
      ActiveSupport::Dependencies.explicitly_unloadable_constants += klasses.collect(&:name)
      klasses.select(&:descends_from_active_record?).select(&:table_exists?).collect(&:name)
    end

    File.open(File.join(RAILS_ROOT, 'test_ps.rb'), File::APPEND+ File::CREAT+ File::WRONLY) do |out|
      unless this_controller.request.xml_http_request? # ajax request do not come from html elements
        notice = @@last_request_ajax ? '#  :: move this line or block up to the last non-ajax request :: ' : ''
        if this_controller.request.method == :get
          out.write "    #{notice}assert_select 'a[href=?]', \"#{this_controller.request.request_uri}\".to_xs\r\n" unless @@last_request_uri == this_controller.request.request_uri if @@last_status =~ /^200/
        else # :post, :put, :delete 
          out.write "    #{notice}assert_select 'form[action=?][method=?]', \"#{this_controller.request.request_uri}\".to_xs, 'post' do \r\n"
          unless this_controller.request.method == :post || this_controller.request.request_uri =~ /\?_method=|\&_method=/
            out.write "      assert_select '*[name=?][value=?]', '_method', '#{this_controller.request.method.to_s.upcase}'\r\n" 
          end
          unless this_controller.request.method == :delete
  #          params = []
            (this_controller.params- [:controller, :action, :authenticity_token, :id, :_method, :commit]- this_controller.request.symbolized_path_parameters.keys).each do |model, value|
              unless value.is_a?(Hash)
                out.write "      assert_select '*[name=?]', '#{model}'\r\n"
              else
                out.write "      assert_select_model_fields :#{model}#{', ' unless value.keys.empty?}#{value.keys.collect(&:to_s).sort.collect(&:inspect).join(', ')}\r\n" 
  #              value.keys.each{|field| params << "#{model}[#{field}]" }
              end
            end
  #          out.write "      assert_select_fields #{params.inspect}\r\n" unless params.empty?
          end
          out.write "    end\r\n"
        end
      end

      original_flash = (this_controller.request.session['flash'] || {}).dup
      unless this_controller.request.xml_http_request?
        action_line = "    #{this_controller.request.method} \"#{this_controller.request.path}\", #{(this_controller.params-[:controller, :action, :authenticity_token, :id, :_method, :commit]-this_controller.request.symbolized_path_parameters.keys).inspect} \# #{Time.now}\r\n"
      else
        action_line = "    xml_http_request :#{this_controller.request.method}, \"#{this_controller.request.path}\", #{(this_controller.params-[:controller, :action, :authenticity_token, :id, :_method]-this_controller.request.symbolized_path_parameters.keys).inspect} \# #{Time.now}\r\n"
      end
      out.write "\r\n"

      if this_controller.request.method == :get
        out.write action_line
        yield
      else
        pre_counters = @@models.build_hash{|klass_name| [klass_name, klass_name.constantize.count]}
        pre_time = 2.seconds.ago
        model = this_controller.class.respond_to?(:model) ? this_controller.class.model : nil
        pre_record = model.find_by_id(this_controller.params[:id]) if model
        yield
        post_counters = @@models.reject{|klass_name| pre_counters[klass_name] == klass_name.constantize.count}.build_hash{|klass_name| [klass_name, klass_name.constantize.count]}
        wrappers = []
        after_wrappers = []
        post_counters.each do |klass_name, count|
          wrappers.push "    assert_difference '#{klass_name}.count', #{count- pre_counters[klass_name]} do \r\n"
        end
        if model
          if this_controller.request.method == :post
            if post_counters.empty?
              wrappers.push "    assert_no_difference '#{model.name}.count' do \r\n"
            elsif post_counters[model.name] && post_counters[model.name]- pre_counters[model.name] == 1
              @@last_created[model.name] = model.find_last
              after_wrappers.push "    created_#{model.name.underscore} = #{model.name}.find_last \# id: #{@@last_created[model.name].id}\r\n"
            else
              @@last_created[model.name] = model.find_last
              after_wrappers.push "    \#created_#{model.name.underscore} = #{model.name}.find_last \# id: #{@@last_created[model.name].id}\r\n"
            end
          end
          if this_controller.request.method == :delete
            if post_counters[model.name]
              wrappers.push "    assert_deleted #{model.name}, #{this_controller.params[:id] || '?'} do \r\n"
            else
              wrappers.push "    assert_no_difference '#{model.name}.count' do \r\n"
            end
          end
          if this_controller.request.method == :put
            record = model.find_by_id(this_controller.params[:id])
            if record && (update_hash = this_controller.params[model.name.underscore])
              received_fields = update_hash.symbolize_keys.keys- [:id]
              updated_fields = received_fields.reject{|field| record[field] == pre_record[field]} if pre_record && record
              updated_values = record.attributes(:only => updated_fields).symbolize_keys
              updated_values.values.each do |value|
                if value.is_a?(Time, DateTime, Date)
                  def value.inspect
                    "#{self.class.name}.parse('#{self}')"
                  end
                end
              end
            end
            if record && record.updated_at >= pre_time && updated_fields
              wrappers.push "    assert_changes_to \"#{model.name}[#{this_controller.params[:id]||'?'}]#{updated_fields.inspect}\", #{(updated_fields.size > 1 ? updated_values : updated_values.values.first).inspect} do \r\n"
            elsif record && record.updated_at >= pre_time
              wrappers.push "    \#assert_changes_to \"#{model.name}[#{this_controller.params[:id]||'?'}][?]\", {?} do \r\n"
            elsif record
              wrappers.push "    assert_no_difference \"#{model.name}[#{this_controller.params[:id]||'?'}]#{received_fields.inspect}\" do \r\n"
            else
              wrappers.push "    \#assert_no_difference \"#{model.name}[#{this_controller.params[:id]||'?'}][?]\" do \r\n"
            end
          end
        end
        wrappers.each_with_index {|wrapper, index| out.write "#{'  '*index}#{wrapper}"}
        out.write "#{'  '*wrappers.size}#{action_line}"
        wrappers.reverse.each_with_index {|wrapper, index| out.write "#{'  '*(wrappers.size-1-index)}    #{'#' if wrapper[4..4]=='#'}end\r\n"}
        after_wrappers.each{|line| out.write "#{line}"}
      end
      out.write "  \r\n"

      this_controller.response.extend(ActionController::TestResponseBehavior)
      flash = this_controller.response.flash.dup || {}
      if used_flags = flash.instance_variable_get('@used')
        used_flags.each{|k, v| flash.delete(k) if v}
      end
      flash.keys.each do |key|
        out.write "    assert_equal '#{flash[key]}', flash[:#{key}]\r\n"
      end
      if this_controller.response.status =~ /^200/
        out.write "    assert_response :success\r\n"
        unless this_controller.response.rendered.blank?
          out.write "    assert_template '#{this_controller.response.rendered}'\r\n"
        else
          out.write "    assert_equal '#{this_controller.response.content_type}', response.content_type\r\n"
        end
        (result_doc = Nokogiri::HTML(this_controller.response.body)).css("body") rescue result_doc = nil
        if result_doc
          original_flash.each do |message_type, message|
            if result_doc.css("div.#{message_type}").first
              out.write "    assert_select 'div.#{message_type}', '#{message}'\r\n"
            elsif result_doc.css("div##{message_type}").first
              out.write "    assert_select 'div##{message_type}', '#{message}'\r\n"
            else
              out.write "\#    assert_select 'div.#{message_type}', '#{message}'\r\n"
            end
          end
          error_message_list = result_doc.css('div.error-messages ul').first
          error_message_fields = result_doc.css('form div.field-with-errors input, form div.field-with-errors textarea, form div.field-with-errors select').collect{|node| node['name']}.sort
          out.write "    assert_select_errors #{error_message_list ? error_message_list.css('li').size : ':none'}#{', ' unless error_message_fields.empty?}#{error_message_fields.collect(&:inspect).join(', ')}\r\n" unless this_controller.request.xml_http_request?
        end
      end
      if this_controller.response.status =~ /^302/
        out.write "    assert_redirected_to \"#{this_controller.response.redirect_url.gsub(/^http:\/\/([a-z0-9]+\.)*([a-z0-9]+):3000\/?/, '/')}\"\r\n"
      end
      @@last_status = this_controller.response.status
      @@last_request_uri = this_controller.request.request_uri unless this_controller.request.xml_http_request?
      @@last_request_ajax = this_controller.request.xml_http_request?
    end
  end

end

# some supporting extentions
class HashWithIndifferentAccess
  def -(keys)
    reject{|key, value| keys.include?(key) }
  end
end

module Enumerable
  def build_hash
    res = {}
    each do |x|
      pair = yield x
      res[pair.first] = pair.last if pair
    end
    res
  end
end
