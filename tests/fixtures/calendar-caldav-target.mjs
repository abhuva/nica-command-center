import http from "node:http";

const host = "127.0.0.1";
const port = Number(process.env.CALENDAR_CALDAV_FIXTURE_PORT || 4493);

const calendarData = [
  "BEGIN:VCALENDAR",
  "VERSION:2.0",
  "BEGIN:VEVENT",
  "UID:synthetic-caldav-event",
  "DTSTART:20300405T100000Z",
  "DTEND:20300405T110000Z",
  "SUMMARY:Synthetic CalDAV event",
  "END:VEVENT",
  "END:VCALENDAR"
].join("\r\n");

const multiStatus = `<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/remote.php/dav/calendars/synthetic-user/fixture/synthetic.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>&quot;synthetic-etag&quot;</d:getetag>
        <c:calendar-data>${calendarData}</c:calendar-data>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>`;

const server = http.createServer((request, response) => {
  if (request.method !== "REPORT") {
    response.writeHead(405, { Allow: "REPORT" });
    response.end();
    return;
  }
  response.writeHead(207, {
    "Content-Type": "application/xml; charset=utf-8",
    "Cache-Control": "no-store"
  });
  response.end(multiStatus);
});

server.listen(port, host, () => {
  console.log(`Synthetic CalDAV target: http://${host}:${port}`);
});
