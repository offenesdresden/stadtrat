#!/usr/bin/env ruby
# coding: utf-8

require 'open-uri'
require 'json'

json = JSON.parse File.read("recordings.json")
json["playlist_src"].each do |entry|
  id = entry["media_id"]
  # # TODO: remove
  # next unless id == 2297325

  source = entry["sources"].find { |source| source["type"] == "application/vnd.apple.mpegurl" }
  unless source
    STDERR.puts "No HLS for media_id #{id.inspect}"
    next
  end
  url = source["src"]
  chapters = []
  entry["textTracks"].each do |track|
    File.write "#{id}_#{track["kind"]}.vtt", URI.open(track["src"]).read
  end
  #status = system "ffmpeg -i '#{url}' -vf 'fps=1,crop=1270:60:540:840,scale=w=iw/2:h=ih/2,format=gray,ocr=language=deu,metadata=mode=print:key=lavfi.ocr.text:file=#{id}_ocr.txt' -af 'whisper=model=ggml-medium.bin:language=de:queue=60:vad_min_silence_duration=1.2:destination=#{id}_speech.srt:format=srt' -f null -"
  unless File.exist? "#{id}_ocr.txt"
    status = system "ffmpeg -i '#{url}' -vf 'fps=1,crop=1270:60:540:840,scale=w=iw/2:h=ih/2,format=gray,negate,ocr=language=deu,metadata=mode=print:key=lavfi.ocr.text:file=#{id}_ocr.txt' -an -f null -"
    unless status
      STDERR.puts "Failed analyzing #{id}"
      exit 1
    end
  end

  unless File.exist? "#{id}_speech"
    status = system "whisperx --model medium --output_format all --language de --compute_type int8 --print_progress True '#{url}' --output_dir '#{id}_speech' --threads 16"
    unless status
      STDERR.puts "Failed analyzing #{id}"
      exit 1
    end
  end
end
