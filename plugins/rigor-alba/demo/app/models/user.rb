# frozen_string_literal: true

Article = Struct.new(:title, :body)
Comment = Struct.new(:text)
User = Struct.new(:id, :name, :articles, :comments)
