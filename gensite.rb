#!/usr/bin/env ruby
# coding: utf-8

require 'date'
require 'erb'
require 'json'

RATSINFO_DATA = "../dresden-ratsinfo"

CHOICES_DE = {
  "yes" => "Ja",
  "no" => "Nein",
  "neutral" => "Enthaltung",
  "absent" => "Abwesend",
  "recused" => "Abgetreten",
  nil => "Unbekannt",
}

FRACTION_COLORS = {
  "SPD" => "#f33",
  "DIE LINKE." => "#e0c",
  "GRÜNE" => "#0d0",
  "CDU" => "#000",
  "AfD" => "#88f",
  "BSW" => "#708",
  "FDP/FB" => "#cc0",
  "Team Zastrow" => "#a82",
  "PVP-Kooperation" => "#f80",
  "PVP" => "#f80",
  "fraktionslos" => "#999",
}

def find_fraction_color(fraction)
  return nil unless fraction

  key = FRACTION_COLORS.keys.sort_by { |name|
    str_distance fraction, name
  }.first

  if str_distance(fraction, key) <= key.length / 3
    FRACTION_COLORS[key]
  else
    nil
  end
end

def str_distance a, b
  DidYouMean::Levenshtein.distance a.downcase, b.downcase
end

def parse_time(s)
  s = s.split(/[\.,]/, 2)
  s[0].split(":").inject(0) { |total, n|
    total * 60 + n.to_i
  } + "0.#{s[1]}".to_f
end

def format_time(time)
  result = ""
  t = time.to_i
  [t / 3600, t / 60 % 60, t % 60].each_with_index do |n, i|
    result += if i == 0
      n.to_s
    else
      ":" + n.to_s.rjust(2, "0")
    end
  end
  result
end

def plural(n, unit)
  if n != 1
    unit = case unit
           when "Stimme"
             "Stimmen"
           else
             "#{unit}s"
           end
  end
  "#{n} #{unit}"
end

class Subtitle
  attr_accessor :start, :stop, :lines, :person, :speaker

  def initialize start, stop
    @start = start
    @stop = stop
    @lines = []
  end

  def text
    lines.join "\n"
  end
end

def read_vtt(input)
  result = []
  subtitle = nil

  input.each_line { |line|
    line.chomp!

    if line =~ /([0-9:\.,]+) --> ([0-9:\.,]+)/
      subtitle = Subtitle.new parse_time($1), parse_time($2)
    elsif subtitle and line == ""
      result << subtitle
      subtitle = nil
    elsif subtitle
      subtitle.lines << line
    end
  }
  result << subtitle if subtitle

  result
end

def read_metadata(input)
  result = []
  time = 0
  subtitle = nil

  input.each_line { |line|
    line.chomp!

    if line =~ /^frame:(\d+)\s+pts:(\d+)\s+pts_time:(\d+)/
      time = $3.to_i
    elsif line =~ /^lavfi\.ocr.text=(.+)/
      text = $1

      if subtitle and subtitle.lines[0] != text
        result << subtitle
        subtitle = nil
      end
      subtitle = Subtitle.new time, time unless subtitle
      subtitle.lines << text if subtitle.lines.last != text
    end
    if subtitle
      subtitle.stop = time
    end
  }
  result << subtitle if subtitle

  result.select { |subtitle| subtitle.lines.any? { |line| not line.empty? } }
end

def read_whisper_json(input)
  JSON.parse(input.read)["segments"].collect { |segment|
    subtitle = Subtitle.new segment["start"], segment["end"]
    subtitle.lines << segment["text"]
    speaker_count = {}
    segment["words"].each do |word|
      next unless word["speaker"]
      speaker_count[word["speaker"]] ||= 0
      speaker_count[word["speaker"]] += 1
    end
    subtitle.speaker = speaker_count.keys.sort_by { |speaker| speaker_count[speaker] }.last
    subtitle
  }
end

class Meeting
  attr_accessor :title, :id, :chapters, :transcript, :ocr, :polls

  def initialize id, title
    @id = id
    @title = title
    @chapters = []
    @transcript = []
    @ocr = []
  end

  def summarize!(agendaitems)
    # Find persons by OCR
    STDERR.puts "Personalizing #{@transcript.size} transcripts"
    personalized_transcript = @transcript.collect do |subtitle|
      ocr = @ocr.find { |ocr|
        subtitle.start >= ocr.start and subtitle.stop <= ocr.stop
      }
      if ocr
        subtitle.person = ocr.person or ocr
      # else
      #   STDERR.puts "No person for #{subtitle.inspect}"
      end
      subtitle
    end

    # Identify diarization speaker by most OCRed person.
    known_speakers = {}
    personalized_transcript.each do |subtitle|
      if subtitle.person.kind_of? Person and subtitle.speaker
        known_speakers[subtitle.speaker] ||= {}
        known = known_speakers[subtitle.speaker]
        known[subtitle.person.title] ||= 0
        known[subtitle.person.title] += 1
      end
    end
    known_speakers.transform_values! do |known|
      person_title = known.keys.sort_by { |person_title| known[person_title] }
                       .last
      PEOPLE.find { |person| person.title == person_title }
    end
    # Interpolate unknown persons by speaker identified through diarization.
    personalized_transcript.each do |subtitle|
      if not(subtitle.person.kind_of? Person) and subtitle.speaker and known_speakers[subtitle.speaker]
        subtitle.person = known_speakers[subtitle.speaker]
      end
    end

    # Group by chapter
    @chapters.collect do |chapter|
      if chapter.text =~ /TOP ([\d\.]+)/
        number = $1
        agendaitem = agendaitems.find { |agendaitem|
          agendaitem["number"] == number
        }
      else
        agendaitem = agendaitems.sort_by { |agendaitem|
          str_distance(chapter.text, "TOP #{agendaitem["number"]} #{agendaitem["name"]}")
        }[0]
      end

      if agendaitem["consultation"]
        consultation = JSON.parse File::read(RATSINFO_DATA + "/consultations/" + agendaitem["consultation"].split("/").last + ".json")
      end

      chapter_polls = polls.select { |poll|
        poll.time >= chapter.start and poll.time < chapter.stop
      }
      STDERR.puts "Chapter: #{chapter.text}"
      STDERR.puts "!= agendaItem: #{agendaitem["name"]}" if str_distance(chapter.text, agendaitem["name"]) > 3
      # Group by speaker, inserting chapters
      transcripts = []
      personalized_transcript.each do |subtitle|
        # Stay within chapter
        next unless subtitle.start >= chapter.start and subtitle.stop <= chapter.stop

        # Flush polls
        while chapter_polls[0] and chapter_polls[0].time < subtitle.start
          transcripts << {
            :kind => :poll,
            :poll => chapter_polls.shift,
          }
        end

        if transcripts.last and transcripts.last[:kind] == :transcript and transcripts.last[:person] == subtitle.person
          prev_subtitle = transcripts.last[:subtitles].last
          if prev_subtitle.stop >= subtitle.start - 1 or
            (prev_subtitle.stop >= subtitle.start - 4 and not(prev_subtitle.text =~ /\.$/m))
            # Concatenate paragraph
            prev_subtitle.stop = subtitle.stop
            prev_subtitle.lines += subtitle.lines
          else
            # Append new paragraph
            transcripts.last[:subtitles] << subtitle
          end
        else
          case subtitle.person
          when Person
            transcripts << {
              :kind => :transcript,
              :person => subtitle.person,
              :subtitles => [subtitle],
            }
          when Subtitle, NilClass
            transcripts << {
              :kind => :transcript,
              :person => nil,
              :subtitles => [subtitle],
            }
          end
        end
      end
      transcripts += chapter_polls.collect { |poll|
        { :kind => :poll,
          :poll => poll,
        }
      }
      
      { :title => chapter.text,
        :agendaitem => agendaitem,
        :consultation => consultation,
        :transcripts => transcripts,
      }
    end
  end
end

class Person
  attr_accessor :name, :affix, :fraction

  def initialize name, affix, fraction
    # Drop middle names, they don't occur in OCR either.
    name_parts = name.split(/\s+/)
    titles = []
    while name_parts[0] =~ /\.$/
      titles << name_parts.shift
    end
    @name = (titles + [name_parts.first, name_parts.last]).join " "
    @affix = affix
    @fraction = fraction
  end

  def title
    s = [@affix, @fraction]
          .compact
          .join ", "
    @name + (s.empty? ? "" : " (#{s})")
  end

  def color
    find_fraction_color(@fraction) or "#777"
  end
end

class Poll
  def initialize(json)
    @json = json
  end

  def time
    @json["time"]
  end

  def image
    @json["image"]
  end

  def groups
    ["yes", "no", "neutral"].collect { |choice|
      voters = @json["voters"]
                 .select { |voter| voter["choice"] == choice }
                 .sort_by { |voter| [voter["fraction"].upcase, voter["person"].upcase] }
                 .collect { |voter|
        voter["bgcolor"] = (find_fraction_color(voter["fraction"]) or "#fff")
        voter["fgcolor"] = voter["bgcolor"] == "#000" ? "#fff" : "#000"
        voter
      }
      if voters.size > 0
        { :choice => choice,
          :count => voters.size,
          :voters => voters,
        }
      end
    }.compact
  end
end

meetings = {}
Dir::foreach(RATSINFO_DATA + "/meetings") do |file|
  next unless file =~ /^\d+\.json$/

  json = JSON.parse File.read(RATSINFO_DATA + "/meetings/" + file)
  next unless json["name"] =~ /Sitzung des Stadtrates/
  date = Time.new(json["start"]).strftime("%Y-%m-%d")
  meetings[date] = json
end

fractions = {}
Dir::foreach(RATSINFO_DATA + "/gremien") do |file|
  next unless file =~ /^\d+\.json$/

  json = JSON.parse File.read(RATSINFO_DATA + "/gremien/" + file)
  next unless json["classification"] =~ /Fraktion/i
  fractions[json["id"]] = json["shortName"] || json["name"]
end
STDERR.puts "Loaded #{fractions.size} fractions"

PEOPLE = []
Dir::foreach(RATSINFO_DATA + "/persons") do |file|
  next unless file =~ /^\d+\.json$/

  person = JSON.parse File.read(RATSINFO_DATA + "/persons/" + file)
  fraction = (person["membership"] or []).select { |membership|
    fractions.has_key?(membership["organization"]) and
    (not(membership["endDate"]) or Date.parse(membership["endDate"]) >= Date.today)
  }.collect { |membership|
    fractions[membership["organization"]]
  }.compact.first
  PEOPLE << Person.new(person["name"], person["affix"], fraction)
end
STDERR.puts "Loaded #{PEOPLE.size} people"

def find_person(name)
  return unless name

  best_distance = nil
  result = nil
  PEOPLE.each do |person|
    distance = str_distance person.name, name
    next if best_distance and distance > best_distance
    next if distance.to_f / person.name.length > 0.3
    best_distance = distance
    result = person
  end
  if best_distance and best_distance > 2
    STDERR.puts "#{best_distance} #{name.inspect} #{result.name.inspect}"
  end
  # STDERR.puts "Cannot find person for OCR #{name.inspect}" unless result
  result
end

index = []
json = JSON.parse File.read("recordings.json")
json["playlist_src"].each do |entry|
  id = entry["media_id"]

  next unless entry["name"] =~ /(\d+)\.\s*(\d+)\.\s*(\d+)/
  unless File.exist? "#{id}_chapters.vtt"
    STDERR.puts "No chapter subtitles for #{id}, skipping."
    next
  end
  unless File.exist? "#{id}_speech/hls.json"
    STDERR.puts "No speech transcript for #{id}, skipping."
    next
  end
  STDERR.puts "Processing recording #{id}"
  date = [$3, $2, $1].collect { |n| n.rjust(2, "0") }.join "-"
  oparl_meeting = meetings[date]
  unless oparl_meeting
    STDERR.puts "No such oparl meeting for #{date}"
    next
  end
  STDERR.puts "Oparl meeting: #{oparl_meeting["id"]} (#{date})"
  meeting = Meeting.new(id, entry["name"])
  meeting.chapters = read_vtt File.open("#{id}_chapters.vtt")
  meeting.polls = JSON.parse(File.read("#{id}_polls.json"))
                    .collect { |poll| Poll::new(poll) }
  # meeting.transcript = read_vtt File.open("#{id}_speech/hls.srt")
  meeting.transcript = read_whisper_json File.open("#{id}_speech/hls.json")
  read_metadata(File.open("#{id}_ocr.txt")).each do |subtitle|
    parts = subtitle.text.split(",")
    name = parts[0]
    subtitle.person = find_person(name)
    if not subtitle.person and name =~ /[A-Z]\S+ [A-Z]\S+[$,]/
      # Invent a person
      STDERR.puts "Inventing person #{name.inspect}"
      PEOPLE << (subtitle.person = Person.new(name, parts[1], nil))
    end

    # Concatenate by found person
    prev_ocr = meeting.ocr.last
    if prev_ocr and prev_ocr.person and prev_ocr.person == subtitle.person
      prev_ocr.stop = subtitle.stop
    else
      meeting.ocr << subtitle
    end
  end

  # Find agendaItem list in this or previous meetings
  agendaitems = oparl_meeting["agendaItem"]
  agendaitems_date = date
  while not(agendaitems) or agendaitems == []
    STDERR.puts "No agendaitems in #{agendaitems_date}"
    agendaitems_date = meetings.keys.filter { |meeting_date| meeting_date < agendaitems_date }
                         .sort
                         .last
    break unless agendaitems_date
    agendaitems = meetings[agendaitems_date]["agendaItem"]
  end
  STDERR.puts "Found agendaitems in #{agendaitems_date}" if agendaitems_date

  summarized = meeting.summarize!(agendaitems)
  videos = entry["sources"].select { |source| source["type"] =~ /^video\// }

  template = <<~EOF
  <!DOCTYPE html>
  <html lang="de" xml:lang="de">
    <head>
      <meta charset="utf-8">
      <title><%= oparl_meeting["name"] %></title>
      <link rel="stylesheet" title="Default" type="text/css" href="style.css">
      <meta name="viewport" content="width=device-width"/>
      <meta name="fediverse:creator" content="@astro@c3d2.social"/>
    </head>
    <body>
      <h1><%= oparl_meeting["name"] %></h1>

      <aside>
        <p><a href="https://ratsinfo.dresden.de/si0056.asp?__ksinr=<%= oparl_meeting["id"].split("/").last %>">Sitzung im Ratsinformationssystem</a></p>
        <p><%= date %></p>
      </aside>

      <nav>
        <p><a href=".">🡄 Übersicht</a></p>

        <h2>Inhaltsverzeichnis</h2>

        <ul>
        <% summarized.each do |chapter| %>
          <li><a href="#agendaitem-<%= chapter[:agendaitem]["number"] %>"><%= chapter[:title] %></a></li>
        <% end %>
        </ul>

        <% videos.each do |video| %>
          <p class="video-link">
            <a href="<%= video["src"] %>" type="<%= video["type"] %>">Videodatei</a>
          </p>
        <% end %>
      </nav>

      <% summarized.each do |chapter| %><article>
        <h2 id="agendaitem-<%= chapter[:agendaitem]["number"] %>"><%= chapter[:title] %></h2>
        <aside>
          <% if chapter[:consultation] %>
            <p><a href="https://ratsinfo.dresden.de/vo0050.asp?__kvonr=<%= chapter[:consultation]["paper"].split("/").last %>">Tagesordnungspunkt im Ratsinformationssystem</a></p>
          <% end %>
        </aside>

        <% chapter[:transcripts].each do |transcript| %>
          <% if transcript[:kind] == :poll %>
            <p class="timestamp"><%= format_time(transcript[:poll].time) %></p>

            <div class="poll">
              <h3>Abstimmung</h3>
              <!--img src="<%= transcript[:poll].image %>" alt="Abstimmung im Videomitschnitt" title="Bild der Abstimmung als Grundlage für darunterstehende Stimmerkennung"-->

              <% transcript[:poll].groups.each do |group| %>
                <div class="group choice-<%= group[:choice] %>">
                  <div class="meta">
                    <h4><%= CHOICES_DE[group[:choice]] %></h4>
                    <p class="count"><%= plural group[:count], "Stimme" %></p>
                  </div>
                  <ul class="voters">
                    <% group[:voters].each do |voter| %>
                      <li style="background-color: <%= voter["bgcolor"] %>; color: <%= voter["fgcolor"] %>">
                        <p class="person"><%= voter["person"] %></p>
                        <p class="fraction"><%= voter["fraction"] %></p>
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="timestamp"><%= format_time(transcript[:subtitles][0].start) %></p>

            <h3 class="speaker" style="border-bottom: 4px solid <%= transcript[:person] ? transcript[:person].color : "#999" %>">
              <% if transcript[:person] %>
                <%= transcript[:person].title %>
              <% else %>
                Unbekannte Person
              <% end %>
            </h3>
            <% transcript[:subtitles].each do |subtitle| %>
              <p class="transcript"><%= subtitle.text %></p>
            <% end %>
          <% end %>
        <% end %>

        <% if chapter[:agendaitem]["result"] or chapter[:agendaitem]["vote"] %>
          <div class="resolution">
            <h3>Beschluss</h4>

            <p class="result">
              <%= chapter[:agendaitem]["result"] %>
            </p>

            <% if chapter[:agendaitem]["vote"] %>
              <div class="vote">
                <% %w(yes no).select { |choice| chapter[:agendaitem]["vote"][choice] > 0 }.each do |choice| %>
                  <div class="choice choice-<%= choice %>" style="flex-basis: <%= (100.0 * chapter[:agendaitem]["vote"][choice] / (chapter[:agendaitem]["vote"]["yes"] + chapter[:agendaitem]["vote"]["no"])).round %>%">
                    <h4><%= CHOICES_DE[choice] %></h4>
                    <p class="count"><%= plural chapter[:agendaitem]["vote"][choice], "Stimme" %></p>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <footer>
          <p><a href=".">🡄 Übersicht</a></p>
        </footer>
      </article><% end %>

      <script async src="https://p.spaceboyz.net/js/pa-qkRTn7-wuUolWOW2bxD9E.js"></script>
      <script>
        window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};
        plausible.init()
      </script>
    </body>
  </html>
  EOF

  outname = "#{oparl_meeting["id"].split("/").last}.html"
  STDERR.puts "Writing #{outname}"
  begin
    html = ERB::new template
    File.write outname, html.result(binding)
  rescue Exception => e
    puts "Exception: #{e}"
    line = e.backtrace.grep(/^\(erb\)/)[0].split(':')[1].to_i
    puts "While evaluating line #{line} of the template:"
    puts template.split("\n")[line-1]
    puts "Backtrace: ", e.backtrace
    exit 1
  end

  index << {
    :name => oparl_meeting["name"],
    :file => outname,
    :chapters => summarized.map { |chapter|
      {
        :id => "agendaitem-" + chapter[:agendaitem]["number"],
        :title => chapter[:title],
        :result => chapter[:agendaitem]["result"],
        :vote => chapter[:agendaitem]["vote"],
      }
    },
  }
end

# write index.html
html = ERB::new <<~EOF
<!DOCTYPE html>
<html lang="de" xml:lang="de">
  <head>
    <meta charset="utf-8">
    <title>Stadtratssitzungen</title>
    <link rel="stylesheet" title="Default" type="text/css" href="style.css">
    <meta name="viewport" content="width=device-width"/>
    <meta name="fediverse:creator" content="@astro@c3d2.social"/>
  </head>
  <body>
    <h1>Stadtratssitzungen</h1>

    <p class="warning">
      Alle Inhalte wurden maschinell erfasst und sind deshalb ohne Gewähr.
    </p>

     <% index.each do |meeting| %><article>
      <h2>
        <a href="<%= meeting[:file] %>">
          <%= meeting[:name] %>
        </a>
      </h2>

      <ul class="agendaitems">
        <% meeting[:chapters].each do |chapter| %>
          <li>
            <a href="<%= meeting[:file] %>#<%= chapter[:id] %>"><%= chapter[:title] %></a>
            <% if chapter[:vote] %>
              <span class="vote">
                <% %w(yes no).select { |choice| chapter[:vote][choice] > 0 }.each do |choice| %>
                  <span class="choice choice-<%= choice %>" style="flex-basis: <%= (100.0 * chapter[:vote][choice] / (chapter[:vote]["yes"] + chapter[:vote]["no"])).round %>%">
                    <%= chapter[:vote][choice] %>
                  </span>
                <% end %>
              </span>
            <% end %>
          </li>
        <% end %>
      </ul>
    </article><% end %>

    <footer>
      <p>
        <a href="https://github.com/offenesdresden/stadtrat">Source</a>
      </p>
      <p>
        <a href="https://c3d2.de/impressum.html">Impressum</a>
      </p>
    </footer>

    <script async src="https://p.spaceboyz.net/js/pa-qkRTn7-wuUolWOW2bxD9E.js"></script>
    <script>
      window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};
      plausible.init()
    </script>
  </body>
</html>
EOF

File.write "index.html", html.result(binding)
