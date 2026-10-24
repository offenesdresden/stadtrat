#!/usr/bin/env ruby
# coding: utf-8

require 'erb'
require 'json'

RATSINFO_DATA = "../dresden-ratsinfo"

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

class Subtitle
  attr_accessor :start, :stop, :lines, :person

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

class Meeting
  attr_accessor :title, :id, :chapters, :transcript, :ocr

  def initialize id, title
    @id = id
    @title = title
    @chapters = []
    @transcript = []
    @ocr = []
  end

  def summarize!(all_agendaitems)
    STDERR.puts "Personalizing #{@transcript.size} transcripts"
    personalized_transcript = @transcript.collect do |subtitle|
      ocr = @ocr.find { |ocr|
        subtitle.start <= ocr.stop and subtitle.stop >= ocr.start - 30
      }
      if ocr
        subtitle.person = ocr.person or ocr
      else
        STDERR.puts "No person for #{subtitle.inspect}"
      end
      subtitle
    end

    @chapters.collect do |chapter|
      agendaitem = all_agendaitems.sort_by { |agendaitem|
        DidYouMean::Levenshtein.distance(chapter.text, agendaitem["name"])
      }[0]
      STDERR.puts "Chapter: #{agendaitem["name"]}"
      if agendaitem["consultation"]
        consultation = JSON.parse File::read(RATSINFO_DATA + "/consultations/" + agendaitem["consultation"].split("/").last + ".json")
      end
      
      transcripts = []
      personalized_transcript.each do |subtitle|
        next unless subtitle.start >= chapter.start and subtitle.stop <= chapter.stop

        if transcripts.last and transcripts.last[:person] == subtitle.person
          prev_subtitle = transcripts.last[:subtitles].last
          if prev_subtitle.stop >= subtitle.start - 1
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
              :person => subtitle.person,
              :subtitles => [subtitle],
            }
          when Subtitle, NilClass
            transcripts << {
              :person => nil,
              :ocr => subtitle.person,
              :subtitles => [subtitle],
            }
          end
        end
      end
      
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
    @name = name
    @affix = affix
    @fraction = fraction
  end

  def title
    s = [@affix, @fraction]
          .compact
          .join ", "
    @name + (s ? " (#{s})" : "")
  end

  def color
    case @fraction
    when /spd/i
      "#f22"
    when /linke/i
      "#d0b"
    when /grüne/i
      "#0c0"
    when /cdu/i
      "#000"
    when /afd/i
      "#57f"
    when /bsw/i
      "#809"
    when /fdp/i
      "#bb0"
    when /zastrow/i
      "#bc0"
    when /pvp/i
      "#f80"
    else "#666"
    end
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
all_agendaitems = meetings.values
                    .collect { |meeting| meeting["agendaItem"] }
                    .flatten
                    .compact

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
  fraction = (person["membership"] or []).collect { |membership| fractions[membership["organization"]] }.compact.first
  PEOPLE << Person.new(person["name"], person["affix"], fraction)
end
STDERR.puts "Loaded #{PEOPLE.size} people"

def find_person(name)
  best_distance = nil
  result = nil
  PEOPLE.each do |person|
    distance = DidYouMean::Levenshtein.distance person.name, name
    next if best_distance and distance > best_distance
    next if distance.to_f / person.name.length > 0.3
    best_distance = distance
    result = person
  end
  if best_distance and best_distance > 2
    STDERR.puts "#{best_distance} #{name.inspect} #{result.name.inspect}"
  end
  STDERR.puts "Cannot find person for OCR #{name.inspect}" unless result
  result
end

index = []
json = JSON.parse File.read("recordings.json")
json["playlist_src"].each do |entry|
  id = entry["media_id"]

  next unless entry["name"] =~ /(\d+)\.\s*(\d+)\.\s*(\d+)/
  STDERR.puts "Processing recording #{id}"
  date = [$3, $2, $1].collect { |n| n.rjust(2, "0") }.join "-"
  oparl_meeting = meetings[date]
  unless oparl_meeting
    STDERR.puts "No such oparl meeting for #{date}"
    next
  end
  STDERR.puts "Oparl meeting: #{oparl_meeting["id"]}"
  meeting = Meeting.new(id, entry["name"])
  meeting.chapters = read_vtt File.open("#{id}_chapters.vtt")
  meeting.transcript = read_vtt File.open("#{id}_speech/hls.srt")
  read_metadata(File.open("#{id}_ocr.txt")).each do |subtitle|
    subtitle.person = find_person(subtitle.text.split(",").first)

    # Concatenate by found person
    prev_ocr = meeting.ocr.last
    if prev_ocr and prev_ocr.person and prev_ocr.person == subtitle.person
      prev_ocr.stop = subtitle.stop
    else
      meeting.ocr << subtitle
    end
  end
  
  summarized = meeting.summarize!(all_agendaitems)

  # TODO: css, link to ratsinfo
  html = ERB::new <<~EOF
  <!DOCTYPE html>
  <html lang="de" xml:lang="de">
    <head>
      <meta charset="utf-8">
      <title><%= oparl_meeting["name"] %></title>
      <link rel="stylesheet" title="Default" type="text/css" href="style.css">
    </head>
    <body>
      <h1><%= oparl_meeting["name"] %></h1>

      <nav>
        <p><a href=".">🡄 Zurück</a></p>

        <h2>Inhaltsverzeichnis</h2>
        <ul>
        <% summarized.each do |chapter| %>
          <li><a href="#agendaitem-<%= chapter[:agendaitem]["number"] %>"><%= chapter[:title] %></a></li>
        <% end %>
        </ul>
      </nav>

      <% summarized.each do |chapter| %><article>
        <h2 id="agendaitem-<%= chapter[:agendaitem]["number"] %>"><%= chapter[:title] %></h2>
        <aside>
          <% if chapter[:consultation] %>
            <p><a href="https://ratsinfo.dresden.de/vo0050.asp?__kvonr=<%= chapter[:consultation]["paper"].split("/").last %>">Tagesordnungspunkt im Ratsinformationssystem</a></p>
          <% end %>
        </aside>

        <% chapter[:transcripts].each do |transcript| %>
          <p class="timestamp"><%= format_time(transcript[:subtitles][0].start) %></p>

          <h3 class="speaker" style="border: 4px solid <%= transcript[:person] ? transcript[:person].color : "#999" %>">
            <% if transcript[:person] %>
              <%= transcript[:person].title %>
            <% else %>
              <span title="<%= transcript[:ocr] ? transcript[:ocr].text : "" %>">
                Unbekannte Person
              </span>
            <% end %>
          </h3>
          <% transcript[:subtitles].each do |subtitle| %>
            <p><%= subtitle.text %></p>
          <% end %>
        <% end %>
      </article><% end %>
    </body>
  </html>
  EOF

  outname = "#{oparl_meeting["id"].split("/").last}.html"
  STDERR.puts "Writing #{outname}"
  File.write outname, html.result(binding)

  index << {
    :name => oparl_meeting["name"],
    :file => outname,
    :chapters => summarized.map { |chapter|
      {
        :id => "agendaitem-" + chapter[:agendaitem]["number"],
        :title => chapter[:title],
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
  </head>
  <body>
    <h1>Stadtratssitzungen</h1>

     <% index.each do |meeting| %><article>
      <h2>
        <a href="<%= meeting[:file] %>">
          <%= meeting[:name] %>
        </a>
      </h2>

      <ul>
        <% meeting[:chapters].each do |chapter| %>
          <li>
            <a href="<%= meeting[:file] %>#<%= chapter[:id]"><%= chapter[:title] %></a>
          </li>
        <% end %>
      </ul>
    </article><% end %>
  </body>
</html>
EOF

File.write outname, html.result(binding)
