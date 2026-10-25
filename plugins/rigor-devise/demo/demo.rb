# frozen_string_literal: true

# Tier B demo. Run from this directory:
#
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# The .rigor.yml in this directory enables the plugin and points signature_paths at the local sig/ stub
# for ActiveRecord + Devise::Models::*. With Tier B active, the substrate's pre-pass walks `class User <
# ApplicationRecord; devise :database_authenticatable, :recoverable; end` and synthesises one
# SyntheticMethod per (User, included module instance method) pair into the SyntheticMethodIndex.
#
# Slice 3 floor (WD13): `user.valid_password?(...)` resolves through the synthetic-method tier and does
# NOT raise call.undefined-method. Its return type is the module's authored RBS return when the stub
# declares one (see `promote_via_origin_module`), and the untyped floor otherwise.

class ApplicationRecord # rubocop:disable Lint/EmptyClass
end

class User < ApplicationRecord
  devise :database_authenticatable, :recoverable, :rememberable, :trackable
end

class Admin < ApplicationRecord
  devise :database_authenticatable, :lockable, :timeoutable
end
