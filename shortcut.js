(function () {
  'use strict';

  var params = new URLSearchParams(window.location.search);
  var fragment = new URLSearchParams(window.location.hash.slice(1).replace(/\+/g, '%2B'));
  var guest = (params.get('guest') || '').toUpperCase();
  var slot = params.get('slot') || 'runner1';
  var title = (params.get('name') || 'Ứng dụng').slice(0, 256);
  var button = document.getElementById('openBtn');
  var status = document.getElementById('status');
  var setupSteps = document.getElementById('setupSteps');
  var standalone = navigator.standalone === true ||
    (typeof window.matchMedia === 'function' && window.matchMedia('(display-mode: standalone)').matches);
  var setup = fragment.has('setup') && !standalone;
  var validGuest = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(guest);

  document.title = title;
  document.getElementById('appTitle').textContent = title;
  document.getElementById('webAppTitle').content = title;

  // Dispatch through the Manager so the requested ticket is written before
  // Runner 1 opens, including when it still hosts a different guest.
  if (!validGuest || (slot !== 'runner1' && slot !== 'main')) {
    setupSteps.hidden = true;
    document.getElementById('intro').textContent = 'Shortcut này thiếu thông tin ứng dụng hợp lệ.';
    status.textContent = 'Mở SIContainer và tạo lại biểu tượng từ ứng dụng bạn muốn dùng.';
    return;
  }

  var icon = fragment.get('icon') || '';
  if (icon.length > 0 && icon.length <= 131072 && /^[A-Za-z0-9+/]+={0,2}$/.test(icon)) {
    var iconURL = 'data:' + (icon.indexOf('iVBOR') === 0 ? 'image/png' : 'image/jpeg') + ';base64,' + icon;
    var iconLink = document.createElement('link');
    iconLink.rel = 'apple-touch-icon';
    iconLink.href = iconURL;
    document.head.appendChild(iconLink);
    var image = document.getElementById('iconImg');
    image.src = iconURL;
    image.hidden = false;
  }

  var target = 'sicontainer://launch?guest=' + encodeURIComponent(guest);
  var identity = guest + ':' + slot;
  var priorState = window.history.state;
  var attempted = !!(priorState && priorState.sicShortcutAttempt === identity);
  var navigation = window.performance && window.performance.getEntriesByType('navigation')[0];
  var restored = navigation && (navigation.type === 'back_forward' || navigation.type === 'reload');
  button.href = target;
  button.textContent = 'Mở ' + title;
  setupSteps.hidden = !setup;
  document.getElementById('intro').textContent = setup
    ? 'Trang này giữ nguyên để bạn thêm biểu tượng vào Màn hình chính.'
    : 'SIContainer sẽ chọn ứng dụng này và mở trên slot đã cấu hình.';

  function recordAttempt() {
    attempted = true;
    // Keep the install URL intact. A query marker would be saved to the Home
    // Screen too and could disable subsequent launches permanently.
    try {
      var state = Object.assign({}, window.history.state, { sicShortcutAttempt: identity });
      window.history.replaceState(state, '', window.location.href);
    } catch (error) {
      // The in-memory flag still prevents repeated automatic dispatch.
    }
    status.textContent = 'Đã gửi yêu cầu mở ' + title + '. Nếu app chưa mở, chạm nút Mở để thử lại.';
  }

  button.addEventListener('click', function () {
    recordAttempt();
    // Keep the anchor's native, user-initiated navigation for iOS URL handling.
  });

  function showResumeMessage() {
    if (attempted) status.textContent = 'Chạm Mở ' + title + ' để tiếp tục.';
  }
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') showResumeMessage();
  });
  window.addEventListener('pageshow', function (event) {
    if (event.persisted) showResumeMessage();
  });

  if (setup) {
    status.textContent = 'Hoàn tất các bước phía trên. Biểu tượng mới sẽ mở ứng dụng từ Màn hình chính.';
  } else if (!attempted && !restored && params.get('launched') !== '1') {
    // Paint the fallback before opening another app. Resuming this document
    // never re-arms automatic launch, including after a canceled open prompt.
    window.requestAnimationFrame(function () {
      window.requestAnimationFrame(function () {
        if (attempted) return;
        recordAttempt();
        window.location.href = target;
      });
    });
  }

  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('./sw.js', { updateViaCache: 'none' }).catch(function () {});
  }
})();
