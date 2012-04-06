$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "enju_ndl/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "enju_ndl"
  s.version     = EnjuNdl::VERSION
  s.authors     = ["Kosuke Tanabe"]
  s.email       = ["tanabe@mwr.mediacom.keio.ac.jp"]
  s.homepage    = "https://github.com/nabeta/enju_ndl"
  s.summary     = "enju_ndl plugin"
  s.description = "NDL WebAPI wrapper for Next-L Enju"

  s.files = Dir["{app,config,db,lib}/**/*"] + ["MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", "~> 3.2"
  s.add_dependency "devise"
  s.add_dependency "nokogiri"
  s.add_dependency "will_paginate", "~> 3.0"
  s.add_dependency "acts_as_list"
  s.add_dependency "attribute_normalizer"
  s.add_dependency "library_stdnums"
  s.add_dependency "enju_subject"
  s.add_dependency "sunspot_rails"
  s.add_dependency "sunspot_solr"

  s.add_development_dependency "sqlite3"
  s.add_development_dependency "rspec-rails"
end
