var failures = [];
var clicks = { mic: 0, camera: 0 };

function check(name, actual, expected) {
  if (actual !== expected) failures.push(name + ': expected ' + expected + ', got ' + actual);
}

function makeToggleButton(kind, label, muted) {
  var button = document.createElement('button');
  button.setAttribute('data-is-muted', muted ? 'true' : 'false');
  button.setAttribute('aria-label', label);
  button.addEventListener('click', function () {
    clicks[kind] += 1;
    var nowMuted = button.getAttribute('data-is-muted') !== 'true';
    button.setAttribute('data-is-muted', nowMuted ? 'true' : 'false');
  });
  return button;
}

// Camera first: a selector that ignores aria-label would wrongly pick it.
function mountCall(micMuted) {
  document.querySelectorAll('button').forEach(function (existing) { existing.remove(); });
  clicks = { mic: 0, camera: 0 };
  document.body.appendChild(makeToggleButton('camera', 'Turn on camera', false));
  var micLabel = micMuted ? 'Turn on microphone' : 'Turn off microphone';
  document.body.appendChild(makeToggleButton('mic', micLabel, micMuted));
}

document.querySelectorAll('button').forEach(function (existing) { existing.remove(); });
check('no buttons -> no-button', meetToggle('query'), 'no-button');

document.body.appendChild(makeToggleButton('camera', 'Turn on camera', false));
check('camera only -> no-button', meetToggle('mute'), 'no-button');
check('camera only -> camera untouched', clicks.camera, 0);

mountCall(false);
check('query unmuted', meetToggle('query'), 'unmuted');
check('query does not click', clicks.mic, 0);

mountCall(false);
check('mute from unmuted returns muted', meetToggle('mute'), 'muted');
check('mute from unmuted clicks mic once', clicks.mic, 1);
check('mute never clicks camera', clicks.camera, 0);

mountCall(true);
check('mute when already muted returns muted', meetToggle('mute'), 'muted');
check('mute when already muted does not click', clicks.mic, 0);

mountCall(true);
check('unmute from muted returns unmuted', meetToggle('unmute'), 'unmuted');
check('unmute from muted clicks mic once', clicks.mic, 1);

mountCall(true);
check('query muted', meetToggle('query'), 'muted');

document.getElementById('results').textContent = failures.length === 0
  ? 'RESULT: ALL PASS'
  : 'RESULT: FAIL ' + failures.join(' | ');
