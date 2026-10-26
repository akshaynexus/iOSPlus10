#!/usr/bin/env python3
"""Static file server + /report?TEXT collector for scripts/metal/webgl-test.sh (bind HOST PORT LOGFILE; cwd = files)."""
import http.server, sys, urllib.parse, datetime
host, port, logfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/report?'):
            q = urllib.parse.unquote(self.path[len('/report?'):].split('&t=')[0])
            line = datetime.datetime.now().strftime('%H:%M:%S') + ' ' + q
            print(line, flush=True)
            with open(logfile, 'a') as f: f.write(line + '\n')
            self.send_response(204); self.send_header('Cache-Control', 'no-store'); self.end_headers(); return
        return super().do_GET()
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store'); super().end_headers()
    def log_message(self, fmt, *a): print('http ' + fmt % a, flush=True)
http.server.ThreadingHTTPServer((host, port), H).serve_forever()
