require 'icalendar'
require 'net/http'
require 'json'

$endpoint = ""

def notify(e, starts_in)
	events = URI('https://calendar.csail.mit.edu/event_calendar')
	lines = Net::HTTP.get(events).split("\n").select { |line| line.include? e.summary }
	# we'll get two hits, a div and the link
	href = URI.join(events, /href="([^"]*)"/.match(lines[1])[1])
	rinfo = Net::HTTP.get(href).scan(/<p>\s*<strong>(.*?):?<\/strong>(.*?)<\/p>/m)
	info = {}
	rinfo.each do |i|
		info[i[0]] = i[1]
			.gsub(/<br( \/)?>/, "\n")
			.strip
			.gsub(/\s+/, " ")
			.gsub(/\s,/, ",")
	end

	update = {
		:text => sprintf("The following talk starts in %d minutes in %s", starts_in/60, e.location),
		:channel => "#seminars",
		:username => "seminar-bot",
		:icon_emoji => ":ear:",
		:attachments => [
			{
				:author_name => info["Speaker"],
				:title => e.summary,
				:text => e.description,
				:fields => [
					{
						:title => "Room",
						:value => e.location,
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

	uri = URI($endpoint)
	res = Net::HTTP.post_form(uri, 'payload' => JSON.generate(update))
	puts res.body
end

begin
	$endpoint = File.open "endpoint.cfg", &:readline
rescue
	abort "endpoint.cfg not found: put the Slack Webhook URL in endpoint.cfg"
end

last = ""
notified = true
while true do
	events = URI('https://calendar.csail.mit.edu/event_calendar.ics')
	response = Net::HTTP.get(events)

	cal = Icalendar.parse(response)
	upcoming = cal.first.events.first
	if last != upcoming.summary then
		last = upcoming.summary
		notified = false
	end
	starts_in = upcoming.dtstart.value.to_time - Time.now

	printf("next event: %s starts in %d minutes\n", upcoming.summary, starts_in/60)

	if starts_in < 15*60 and not notified then
		notify upcoming, starts_in
		notified = true
	end
	sleep 60
end
