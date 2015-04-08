require 'icalendar'
require 'net/http'
require 'json'

$endpoint = ""

def notify(e, starts_in)
	puts "  -> finding event url in event calendar"
	events = URI('https://calendar.csail.mit.edu/event_calendar')
	lines = Net::HTTP.get(events).split("\n").select { |line| line.include? e.summary }
	# we'll get two hits, a div and the link
	href = URI.join(events, /href="([^"]*)"/.match(lines[1])[1])
	puts "  -> url is #{href}"
	puts "  -> retrieving detailed event information"
	rinfo = Net::HTTP.get(href).scan(/<p>\s*<strong>(.*?):?<\/strong>(.*?)<\/p>/m)
	info = {}
	rinfo.each do |i|
		info[i[0]] = i[1]
			.gsub(/<br( \/)?>/, "\n")
			.strip
			.gsub(/\s+/, " ")
			.gsub(/\s,/, ",")
			.encode("UTF-8")
	end

	update = {
		:text => sprintf("The following talk starts in %d minutes in %s", starts_in/60, info["Location"]),
		:channel => "#seminars",
		:username => "seminar-bot",
		:icon_emoji => ":ear:",
		:attachments => [
			{
				:author_name => info["Speaker"],
				:title => e.summary.strip.force_encoding("UTF-8"),
				:text => e.description.strip.force_encoding("UTF-8"),
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
		update[:attachments][:title_link] = info["Relevant URL"]
	end

	puts "  -> sending notification payload to Slack"

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
wtime = 15*60
notified = true
while true do
	events = URI('https://calendar.csail.mit.edu/event_calendar.ics')
	response = Net::HTTP.get(events)

	cal = Icalendar.parse(response)
	starts_in = -1
	while starts_in < 0 do
		upcoming = cal.first.events.shift
		# dtstart is initialized as a local time, when it is really a Boston time
		start = upcoming.dtstart.value.to_time - Time.now.getlocal('-04:00').gmt_offset
		starts_in = start - Time.now
	end

	if last != upcoming.summary then
		puts ":: next event is at #{upcoming.dtstart}"
		puts ":: #{upcoming.summary.strip}"
		last = upcoming.summary
		notified = false
	end

	printf("==> next event starts in %d minutes\n", (starts_in/60).floor)
	STDOUT.flush

	if starts_in < wtime and not notified then
		puts "==> event about to start, notifying Slack channel"
		notify upcoming, starts_in
		puts "==> Slack channel notified\n"
		notified = true
		puts "==> waiting for event to start"
		sleep starts_in+1
	elsif starts_in > wtime then
		sleep2 starts_in - wtime
	else
		# sleep until after the event has started
		sleep starts_in+1
	end
end
