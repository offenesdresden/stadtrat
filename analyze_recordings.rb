#!/usr/bin/env ruby
# coding: utf-8

require 'open-uri'
require 'json'
require 'chunky_png'

class Array
  def median
    sorted = self.sort
    mid = (sorted.length - 1) / 2.0
    (sorted[mid.floor] + sorted[mid.ceil]) / 2
  end
end

def str_distance a, b
  DidYouMean::Levenshtein.distance a.downcase, b.downcase
end

json = JSON.parse File.read("recordings.json")
json["playlist_src"].each do |entry|
  id = entry["media_id"]

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
      STDERR.puts "Failed analyzing #{id} for persons"
      exit 1
    end
  end

  unless false and File.exist? "#{id}_polls.json"
    unless File.exist? "#{id}_poll.txt"
      status = system "ffmpeg -i '#{url}' -vf 'fps=1,crop=330:80:590:150,scale=w=iw/2:h=ih/2,format=gray,negate,ocr=language=deu,metadata=mode=print:key=lavfi.ocr.text:file=#{id}_poll.txt' -an -f null -"
      unless status
        STDERR.puts "Failed analyzing #{id} for polls"
        exit 1
      end
    end
    poll_times = []
    poll_time = nil
    File.read("#{id}_poll.txt").scan(/pts_time:(\d+)\nlavfi\.ocr\.text=Abstimmung$/m) do |m|
      now = m[0].to_i
      # Find the last second of a poll
      if poll_time and poll_time + 1 < now
        poll_times << poll_time
      end
      poll_time = now
    end
    poll_times << poll_time

    polls = []
    poll_times.each do |poll_time|
      prefix = "#{id}_#{poll_time}"
      unless File.exist? "#{prefix}_1.png"
        status = system "ffmpeg -ss #{poll_time} -t 1 -i '#{url}' -an -vf 'crop=1306:676:103:69' -y '#{id}_#{poll_time}_%d.png'"
        unless status
          STDERR.puts "Failed analyzing #{id} for polls"
          exit 1
        end
      end

      # Find the last image with poll results.
      Dir["#{prefix}_*.png"].sort_by { |a| a.split("_").map { |n| n.to_i } }.reverse_each do |filename|
        outname = filename.sub(/\.png$/, "")
        # Perform full-frame OCR
        STDERR.puts "Analyzing #{outname}"
        status = system "tesseract -l deu --psm sparse_text_osd '#{filename}' '#{outname}' output tsv -c preserve_interword_spaces=1 2>/dev/null"
        unless status
          STDERR.puts "Failed OCRing #{filename}"
          exit 1
        end

        ocr = []
        header = nil
        File.readlines("#{outname}.tsv", chomp: true).each do |line|
          fields = line.split("\t")
          unless header
            header = fields
          else
            data = Hash[header.zip fields]
            data.each do |k, v|
              if k != "text"
                data[k] = v.to_i
              end
            end
            ocr << data if data["text"].to_s.strip != ""
          end
        end

        # Concatenate OCR segments that belong together
        ocr_concat = []
        while data1 = ocr.pop
          x1 = data1["left"] + data1["width"]
          y1 = data1["top"]

          data2 = nil
          # Find flush text to the right.
          loop do
            data2 = ocr.find { |data2|
              x2 = data2["left"]
              y2 = data2["top"]
              x1 + 20 > x2 and x1 <= x2 and
                y1 + 6 > y2 and y1 - 6 < y2
            }
            break unless data2
            ocr.delete data2
            # pp :merge => [data1, data2]
            data1["text"] += " " + data2["text"]
            data1["width"] = data2["left"] + data2["width"] - data1["left"]
          end

          x1 = data1["left"]
          # Find flush text to the left.
          loop do
            data2 = ocr.find { |data2|
              x2 = data2["left"] + data2["width"]
              y2 = data2["top"]
              x2 + 20 > x1 and x2 <= x1 and
                y1 + 6 > y2 and y1 - 6 < y2
            }
            break unless data2
            ocr.delete data2
            # pp :merge => [data2, data1]
            data1["text"] = data2["text"] + " " + data1["text"]
            data1["width"] = data1["left"] + data1["width"] - data2["left"]
            data1["left"] = data2["left"]
          end

          ocr_concat << data1
        end
        ocr = ocr_concat

        data_abstimmung = ocr.find { |data| data["text"] =~ /Abstimmung/ }
        # Skip to previous frame
        unless data_abstimmung
          STDERR.puts "No poll in #{outname}"
          next
        end

        data_time = ocr.select { |data|
          data["top"] >= data_abstimmung["top"] - 10 and
            data["top"] < data_abstimmung["top"] + 20 and
            data["left"] <= data_abstimmung["left"]
        }.sort { |data|
          data["left"]
        }.map { |data|
          data["text"]
        }.join ""
        unless data_time =~ /:00/
          STDERR.puts "No poll end time in #{outname}"
          next
        end

        # Find voters.
        voters = []
        ocr.each_with_index do |data1, i|
          ocr.each_with_index do |data2, j|
            next if i == j

            x1 = data1["left"]
            y1 = data1["top"] + data1["height"]
            x2 = data2["left"]
            y2 = data2["top"]
            if not(data1["text"].start_with? "[") and data2["text"].start_with? "[" and
              not(data1["text"].end_with? "]") and data2["text"].end_with? "]" and
              x1 - 4 < x2 and x1 + 4 > x2 and
              y1 - 6 < y2 and y1 + 8 > y2

              voters << {
                :person => data1,
                :fraction => data2,
              }
            end
          end
        end

        # Look for vote color.
        voters.collect! do |vote|
          { :person => vote[:person],
            :fraction => vote[:fraction],
          }
        end
        frame_times = filename.split("_")[1..2].map(&:to_i)
        polls << {
          :voters => voters,
          :time => frame_times[0] + frame_times[1] / 25.0,
          :image => filename,
        }
        STDERR.puts "Recognized a poll with #{voters.size} voters"
        break
      end
    end

    # Group all polls+voter by coords
    voters = []
    STDERR.puts "Grouping voters from #{polls.size} polls"
    polls.each do |poll|
      poll[:voters].each do |voter|
        x1 = voter[:person]["left"]
        y1 = voter[:person]["top"]
        found = false
        voters.each do |votes|
          x2 = votes[0][:person]["left"]
          y2 = votes[0][:person]["top"]
          # if str_distance(votes[0][:person]["text"], voter[:person]["text"]) < 4 and
          #   str_distance(votes[0][:fraction]["text"], voter[:fraction]["text"]) < 4 and
          if x1 + 16 > x2 and x1 - 16 < x2 and
            y1 + 8 > y2 and y1 - 8 < y2

            # Merge
            votes << voter
            found = true
            break
          end
        end
        # Append unmerged
        voters << [voter] unless found
      end
    end
    voters.collect! do |votes|
      # Use most-frequent text
      persons = {}
      votes.each do |vote|
        person = vote[:person]["text"]
        persons[person] ||= 0
        score = person =~ /[,;]/ ? 0.2 : 1
        persons[person] += score
      end
      person = persons.keys.sort_by { |person| persons[person] }.last

      fractions = {}
      votes.each do |vote|
        fraction = vote[:fraction]["text"].gsub(/[\[\]]/, "")
        fractions[fraction] ||= 0
        fractions[fraction] += 1
      end
      fraction = fractions.keys.sort_by { |fraction| fractions[fraction] }.last

      # Median for coords
      { :person => person,
        :fraction => fraction,
        :left => votes.collect { |vote| vote[:person]["left"] }.median,
        :top => votes.collect { |vote| vote[:person]["top"] }.median,
      }
    end
    STDERR.puts "Found #{voters.size} voters"

    # Recognize choices by color
    polls.collect! do |poll|
      image = ChunkyPNG::Image.from_file(poll[:image])

      poll[:voters] = voters.collect do |voter|
        x = voter[:left] - 16
        y = voter[:top] + 16
        pixel = image[x, y]
        r = ChunkyPNG::Color.r(pixel)
        g = ChunkyPNG::Color.g(pixel)
        b = ChunkyPNG::Color.b(pixel)
        choice = if r > 5 * g and r > 5 * b
                   :no
                 elsif g > 5 * r and g > 5 * b
                   :yes
                 elsif r > 5 * b and g > 5 * b
                   :neutral
                 else
                   STDERR.puts "Unknown vote color: ##{[r, g, b].map { |c| c.to_s(16).rjust(2, "0") }.join ""}"
                 end
        {
          :person => voter[:person],
          :fraction => voter[:fraction],
          :choice => choice,
        }
      end
      STDERR.puts "Recognized a poll with " + [:yes, :no, :neutral, nil].map { |choice|
        "#{choice}: #{poll[:voters].select { |voter| voter[:choice] == choice }
          .size}"
      }.join(" ")
      poll
    end

    polls.sort_by! { |poll| poll[:time] }
    File.write("#{id}_polls.json", polls.to_json)
  end

  unless true or File.exist? "#{id}_speech"
    status = system "whisperx --model medium --output_format all --language de --compute_type int8 --print_progress True '#{url}' --output_dir '#{id}_speech' --threads 16"
    unless status
      STDERR.puts "Failed analyzing #{id}"
      exit 1
    end
  end
end
