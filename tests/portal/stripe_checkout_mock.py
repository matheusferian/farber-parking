# LOCAL ONLY fake of Stripe's POST /v1/checkout/sessions for the Valet Pass
# gratuity tests (never talks to Stripe). valet-pass reaches it through
# AIRVALET_STRIPE_API_BASE, which the function honors only with a *_test_ key.
#   python3 tests/portal/stripe_checkout_mock.py 8798
# GET /__log → every session created (form fields, Idempotency-Key); POST /__reset.
import http.server, json, sys, threading, urllib.parse

KEY = 'rk_test_localmock0000000000'
LOCK = threading.Lock()
SESSIONS, BY_KEY = [], {}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == '/__log':
            with LOCK: return self.send(200, SESSIONS)
        self.send(404, {})
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0); raw = self.rfile.read(n).decode()
        if self.path == '/__reset':
            with LOCK: SESSIONS.clear(); BY_KEY.clear()
            return self.send(200, {'ok': True})
        if self.path != '/v1/checkout/sessions': return self.send(404, {'error': {'message': 'not mocked'}})
        if self.headers.get('Authorization') != 'Bearer ' + KEY: return self.send(401, {'error': {'type': 'invalid_request_error'}})
        form = dict(urllib.parse.parse_qsl(raw, keep_blank_values=True)); key = self.headers.get('Idempotency-Key') or ''
        with LOCK:
            if key and key in BY_KEY:
                s = BY_KEY[key]
                if s['form'] != form: return self.send(400, {'error': {'type': 'idempotency_error'}})
                return self.send(200, s['resp'])
            sid = 'cs_test_mock_%d' % (len(SESSIONS) + 1)
            resp = {'id': sid, 'object': 'checkout.session', 'url': 'https://checkout.stripe.com/c/pay/' + sid, 'mode': form.get('mode'),
                    'amount_total': int(form.get('line_items[0][price_data][unit_amount]') or 0), 'client_reference_id': form.get('client_reference_id'),
                    'metadata': {k[9:-1]: v for k, v in form.items() if k.startswith('metadata[')}, 'payment_status': 'unpaid'}
            s = {'id': sid, 'key': key, 'form': form, 'resp': resp}; SESSIONS.append(s)
            if key: BY_KEY[key] = s
        self.send(200, resp)

if __name__ == '__main__':
    http.server.ThreadingHTTPServer(('0.0.0.0', int(sys.argv[1]) if len(sys.argv) > 1 else 8798), H).serve_forever()
