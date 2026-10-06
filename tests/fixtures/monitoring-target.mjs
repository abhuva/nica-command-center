import http from "node:http";

const host = "127.0.0.1";
const port = Number(process.env.MONITORING_FIXTURE_PORT || 4399);

const server = http.createServer((request, response) => {
  if (request.method !== "HEAD" && request.method !== "GET") {
    response.writeHead(405, { Allow: "GET, HEAD" });
    response.end();
    return;
  }
  response.writeHead(204, { "Cache-Control": "no-store" });
  response.end();
});

server.listen(port, host, () => {
  console.log(`Synthetic monitoring target: http://${host}:${port}`);
});
