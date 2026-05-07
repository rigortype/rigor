# frozen_string_literal: true

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Tiny inflection helper for the common `ClassName → snake_case_plural`
      # mapping Rails uses to derive table names. Deliberately
      # narrow — handles the regular cases (`User → users`,
      # `BlogPost → blog_posts`, `Category → categories`,
      # `Bus → buses`, `Wolf → wolves`). Irregular plurals
      # (`Person → people`, `Mouse → mice`, `Datum → data`) are
      # NOT handled; the user is expected to declare
      # `self.table_name = "people"` for those.
      #
      # Avoids an `activesupport` runtime dependency. Rails apps
      # that need richer inflection should set explicit table
      # names on the affected models.
      module Inflector
        IRREGULAR_PLURALS = {
          # Common ones we still want to handle without bringing
          # in a full inflection table. Users get the configured
          # explicit table_name route for anything else.
          "person" => "people",
          "child" => "children",
          "datum" => "data"
        }.freeze

        module_function

        # `BlogPost` → `blog_posts`. `User::Profile` → `user_profiles`
        # (Rails-style namespacing flattens with underscore).
        def tableize(class_name)
          underscore = underscore(class_name.to_s.gsub("::", "/"))
          # `user/profiles` → `user_profiles`
          underscore = underscore.tr("/", "_")
          pluralize(underscore)
        end

        # `BlogPost` → `blog_post`. Standard Rails-style underscore.
        def underscore(camel_case_word)
          word = camel_case_word.to_s.dup
          word.gsub!(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          word.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
          word.tr!("-", "_")
          word.downcase!
          word
        end

        # `user` → `users`, `category` → `categories`,
        # `bus` → `buses`, `wolf` → `wolves`. Falls back to a
        # plain `+ "s"` for unrecognised endings.
        def pluralize(word)
          return IRREGULAR_PLURALS[word] if IRREGULAR_PLURALS.key?(word)

          case word
          when /(.*[bcdfghjklmnpqrstvwxz])y\z/
            # `category` → `categories`, `cherry` → `cherries`
            "#{Regexp.last_match(1)}ies"
          when /(.*[sxz]|.*[cs]h)\z/
            # `bus` → `buses`, `box` → `boxes`, `dish` → `dishes`
            "#{Regexp.last_match(0)}es"
          when /(.*)fe?\z/
            # `wolf` → `wolves`, `knife` → `knives`
            "#{Regexp.last_match(1)}ves"
          else
            "#{word}s"
          end
        end
      end
    end
  end
end
