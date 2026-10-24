#!/usr/bin/env ruby
# coding: utf-8

require 'open-uri'
require 'nokogiri'
require 'json'

doc = Nokogiri::HTML URI.open("https://www.sachsen-fernsehen.de/embed/1511323/9d65wl3lx2bb2").read.force_encoding("UTF-8")
doc.css('video').each do |video|
  json = JSON.parse video.attr("data-vjs_setup")
  data = JSON.generate(json, { indent: "  " })
  File.write("recordings.json", data)
end
