import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/tools/site_start_guard.dart';

void main() {
  test('rejects python app.py, http.server, flask run, and nohup', () {
    expect(looksLikeSiteStartCommand('python3 app.py'), isTrue);
    expect(
      looksLikeSiteStartCommand(
        'cd /root/projects/p && python3 app.py > /tmp/flask.log 2>&1 &',
      ),
      isTrue,
    );
    expect(
      looksLikeSiteStartCommand(
        'nohup python3 app.py > /tmp/flask.log 2>&1 &',
      ),
      isTrue,
    );
    expect(
      looksLikeSiteStartCommand('python3 -m http.server 8765 --bind 127.0.0.1'),
      isTrue,
    );
    expect(looksLikeSiteStartCommand('flask run --port 8765'), isTrue);
    expect(
      siteStartBypassError('python3 app.py'),
      kSiteStartBypassError,
    );
  });

  test('rejects the registered start command even when wrapped', () {
    expect(
      looksLikeSiteStartCommand(
        'source /root/venv/bin/activate && python3 app.py',
        registeredStartCommand: 'python3 app.py',
      ),
      isTrue,
    );
  });

  test('allows inspect, install, and python -c checks', () {
    expect(looksLikeSiteStartCommand('cat /root/projects/p/app.py'), isFalse);
    expect(
      looksLikeSiteStartCommand('python3 -c "from app import app; print(1)"'),
      isFalse,
    );
    expect(
      looksLikeSiteStartCommand('python3 -c "import flask; print(flask.__version__)"'),
      isFalse,
    );
    expect(looksLikeSiteStartCommand('apk add --no-cache py3-flask'), isFalse);
    expect(looksLikeSiteStartCommand('curl -s http://127.0.0.1:8765/'), isFalse);
    expect(looksLikeSiteStartCommand('python3 -m venv /root/venv'), isFalse);
    expect(siteStartBypassError('ls'), isNull);
  });
}
