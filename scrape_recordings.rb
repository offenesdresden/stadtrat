#!/usr/bin/env ruby
# coding: utf-8

require 'open-uri'
require 'nokogiri'
require 'json'

old = JSON.parse File.read("recordings.json")
old_entries = {}
old["playlist_src"].each do |entry|
  old_entries[entry["media_id"]] = entry
end

doc = Nokogiri::HTML URI.open("https://www.sachsen-fernsehen.de/embed/1511323/9d65wl3lx2bb2").read.force_encoding("UTF-8")
doc.css('video').each do |video|
  new = JSON.parse video.attr("data-vjs_setup")

  new["playlist_src"].each do |entry|
    old_entries.delete entry["media_id"]
  end
  new["playlist_src"] += old_entries.values

  data = JSON.pretty_generate(new)
  File.write("recordings.json", data)
end
