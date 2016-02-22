#!/usr/bin/env ruby

require 'icalendar'
require 'net/http'
require 'tzinfo'
require 'json'
require 'cgi'

$endpoint = ""

$cookie = ""
$ref = ""
def fetch(url, request_max = 5)
	raise "Max number of redirects reached" if request_max <= 0

	uri = URI(url)

	http = Net::HTTP.new(uri.host, uri.port)
	http.use_ssl = uri.port != 80

	options = {}
	options["Cookie"] = $cookie if $cookie != ""
	options["Referer"] = $ref if $ref != ""

	req = Net::HTTP::Get.new(sprintf("%s?%s", uri.path, uri.query), options)
	res = http.request req

	case res
	when Net::HTTPOK
		$ref = ""
		return res.body.force_encoding("UTF-8")
	when Net::HTTPFound, Net::HTTPMovedPermanently
		begin
			$cookie = res.fetch "Set-Cookie"
		rescue
		end
		$ref = url
		return fetch(res.fetch('location'), request_max - 1)
	else
		$ref = ""
		return res.body.force_encoding("UTF-8")
	end
end

def slackify(text, root)
	CGI.unescapeHTML(
		text
		.gsub(/<br( \/)?>/, "\n")
		.gsub(/\n\n+/, "<br />")
		.gsub(/\n/, " ")
		.gsub(/<br \/>/, "\n\n")
		.gsub(/<i>([^<]*)<\/i>/, "*\\1*")
		.gsub(/<a [^>]*href="([^"]+)"[^>]*>([^<]+)<\/a>/) {|m| "<#{URI.join(root, $1)}|#{$2}>"}
		.strip
		.gsub(/ +/, " ")
		.gsub(/\s,/, ",")
	)
end

def notify(e, starts_in)
	puts "  -> finding event url in event calendar"

	events = 'https://calendar.csail.mit.edu/event_calendar'
	#events = 'https://peeps-test.csail.mit.edu:8443/event_calendar'

	lines = fetch(events).split("\n").select { |line| line.include? CGI.escapeHTML(e.summary) }
	# we'll get two hits, a div and the link
	if lines.length != 2
		puts "!! failed to parse event calendar page"
		puts "looked for #{CGI.escapeHTML(e.summary)} in \n#{fetch(events)}"
		puts "gave:", lines
		return
	end
	href = /href="([^"]*)"/.match(lines[1])
	if href.nil? || href.length < 2
		puts "!! failed to parse event calendar page"
		puts "lines:", lines
		puts "match:", href
		return
	end
	href = URI.join(events, href[1])
	puts "  -> url is #{href}"
	puts "  -> retrieving detailed event information"
	rinfo = fetch(href).scan(/<p>\s*<strong>(.*?):?<\/strong>(.*?)<\/p>/m)
	info = {}
	rinfo.each do |i|
		info[i[0]] = slackify(i[1], events)
	end

	update = {
		:text => sprintf("The following talk starts in %d minutes in %s", starts_in/60, info["Location"]),
		:username => "seminar-bot",
		:icon_emoji => ":ear:",
		:attachments => [
			{
				:author_name => info["Speaker"],
				:title => slackify(e.summary.force_encoding("UTF-8"), events),
				:text => slackify(e.description.force_encoding("UTF-8"), events),
				:fields => [
					{
						:title => "Room",
						:value => info["Location"],
						:short => true
					},
					{
						:title => "Time",
						:value => info["Time"],
						:short => true
					},
					{
						:title => "Host",
						:value => info["Host"],
						:short => true
					},
					{
						:title => "Refreshments",
						:value => info["Refreshments"],
						:short => true
					}
				]
			}
		]
	}
	if info["Relevant URL"] != "" then
		update[:attachments][0][:title_link] = info["Relevant URL"]
	end

	puts "  -> sending notification payload to Slack"
	STDOUT.flush

	uri = URI($endpoint)
	res = Net::HTTP.post_form(uri, 'payload' => JSON.generate(update))
	puts res.body
end

begin
	$endpoint = File.open "endpoint.cfg", &:readline
	$endpoint.chomp!
rescue
	abort "endpoint.cfg not found: put the Slack Webhook URL in endpoint.cfg"
end

def sleep2(s)
	sleep 60 * ((s/60)/2).ceil
end

last = ""
wtimem = 15
notified = true
while true do
	response = fetch('https://calendar.csail.mit.edu/event_calendar.ics')
	#response = fetch('https://peeps-test.csail.mit.edu:8443/event_calendar.ics')

	begin
		cal = Icalendar.parse(response)
	rescue
		puts "!! failed to parse event calendar; dumped to parse-failed.ical"
		File.open "parse-failed.ical", 'w' do |f|
			f.write(response)
		end
		sleep 60*60
		next
	end

	if cal.first.nil? then
		puts ":: no upcoming events; sleeping for a day"
		sleep 24*60*60
		next
	end

	starts_in = -1
	while starts_in < 0 do
		upcoming = cal.first.events.shift
		# dtstart is initialized as a local time, when it is really a Boston time
		here = TZInfo::Timezone.get(upcoming.dtstart.ical_params['tzid'][0])
		start = upcoming.dtstart.to_time
		starts_in = start - here.now
	end

	if last != upcoming.summary then
		puts ":: next event is at #{upcoming.dtstart}"
		puts ":: #{upcoming.summary.strip}"
		last = upcoming.summary
		notified = false
	end

	if starts_in < 60*(wtimem+1) and not notified then
		puts "==> event about to start, notifying Slack channel"
		STDOUT.flush

		notify upcoming, starts_in
		notified = true

		puts "==> Slack channel notified\n"
		STDOUT.flush
	elsif starts_in > 60*wtimem then
		printf("==> next event starts in %d minutes\n", (starts_in/60).floor)
		STDOUT.flush

		sleep2 starts_in - 60*wtimem
	else
		puts "==> waiting for event to start"
		STDOUT.flush
		sleep starts_in+1
	end
end
