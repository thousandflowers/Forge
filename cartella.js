// The folder at the top of the page: files that rename themselves, or that you rename by clicking.
(() => {
  const IMG = Object.fromEntries([
    ['goose', 480, 320], ['gooseTall', 360, 498], ['desktop', 520, 292], ['upload', 480, 360], ['m4aTxt', 480, 360],
    ['anvil', 480, 360], ['rename', 480, 360], ['screenshot', 560, 409], ['form', 360, 480], ['logoTall', 360, 480],
  ].map(([k, w, h]) => [k, { src: `media/files/${k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}.jpg`, ar: w / h }]));

  // [name, what is typed, looks like, becomes, picture, extension it ends with].
  // A word is used up when the file is done (beach_gray.heic ends as beach.heic), as Forge 0.3.0 does; _round40 ends as .png.
  const ROWS = [
    ['Letter.md', '.pdf', 'md', 'pdf'], ['beach.heic', '_gray', 'photo', 'gray', 'goose'], ['clip.mov', '.gif', 'film', 'gif', 'upload'],
    ['talk.m4a', '.txt', 'm4a', 'txt'], ['Window.png', '_round40', 'photo', 'round', 'screenshot'], ['sheet.jpg', '_scan', 'scan', 'scanned'],
    ['Desktop.jpg', '_crop1x1', 'photo', 'square', 'desktop'],
    ['notes.docx', '.pdf', 'docx', 'pdf'], ['goose.jpg', '_gray', 'photo', 'gray', 'gooseTall'], ['Forge.jpg', '_round40', 'photo', 'round', 'logoTall', '.png'],
    ['memo.m4a', '.txt', 'm4a', 'txt'], ['form.jpg', '_crop1x1', 'photo', 'square', 'form'], ['party.mov', '.gif', 'film', 'gif', 'anvil'],
    ['song.wav', '.txt', 'wav', 'txt'], ['receipt.jpg', '_scan', 'scan', 'scanned'],
    ['Plan.md', '.pdf', 'md', 'pdf'], ['rename.png', '_gray', 'photo', 'gray', 'rename'], ['kite.mov', '.gif', 'film', 'gif', 'goose'],
    ['call.m4a', '.txt', 'm4a', 'txt'], ['anvil.jpg', '_round40', 'photo', 'round', 'm4aTxt', '.png'], ['README.md', '.pdf', 'md', 'pdf'],
    ['dusk.heic', '_crop1x1', 'photo', 'square', 'goose'],
  ];
  const FILES = ROWS.map(([a, word, from, to, img, outExt]) => {
    const dot = a.lastIndexOf('.'), stem = a.slice(0, dot), ext = a.slice(dot);
    const typed = word.startsWith('.') ? stem + word : stem + word + ext;
    const b = word.startsWith('.') ? typed : stem + (outExt || ext);
    return { a, word, typed, b, from, to, img: { img: IMG[img] } };
  });

  const grid = document.getElementById('files');
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const nodes = FILES.map((f) => {
    const el = document.createElement('button');
    el.className = 'f'; el.type = 'button';
    el.setAttribute('aria-label', `${f.a}. Rename it ${f.typed}`);
    el.innerHTML = `<div class="pic">${FF.draw(f.from, f.img)}</div><span class="lbl">${esc(f.a)}</span><span class="word" aria-hidden="true">${esc(f.word)}</span>`;
    grid.append(el);
    return { f, el, busy: false, done: false };
  });
  const lbl = (n) => n.el.querySelector('.lbl');
  const typing = (n) => (pre, mid, suf, mode) => {
    lbl(n).innerHTML = esc(pre) + (mode === 'sel' ? `<span class="sel">${esc(mid)}</span>` : esc(mid) + '<span class="caret"></span>') + esc(suf);
  };

  async function rename(n, still) {
    if (n.busy || n.done) return;
    n.busy = true; n.el.classList.add('busy');
    if (!still) {
      n.el.classList.add('picked'); await FF.sleep(380);
      n.el.classList.replace('picked', 'editing');
      await FF.retype(n.f.a, n.f.typed, typing(n), 78);
      await FF.sleep(260);
      n.el.classList.remove('editing'); lbl(n).textContent = n.f.typed;
      await FF.sleep(240);
      n.el.classList.add('hit');
    }
    n.el.querySelector('.pic').innerHTML = FF.draw(n.f.to, n.f.img);
    if (!still && n.f.b !== n.f.typed) {
      // The word goes away: show it leaving, then the name Forge leaves behind.
      const { pre, oldMid, newMid, suf } = FF.split(n.f.typed, n.f.b);
      lbl(n).innerHTML = `${esc(pre)}<span class="gone at-start">${esc(oldMid)}</span>${esc(newMid)}${esc(suf)}`;
      requestAnimationFrame(() => requestAnimationFrame(() => lbl(n).querySelector('.gone')?.classList.remove('at-start')));
      await FF.sleep(420);
    }
    lbl(n).textContent = n.f.b;
    n.el.classList.remove('hit', 'busy'); n.el.classList.add('done');
    n.el.setAttribute('aria-label', n.f.b);
    n.busy = false; n.done = true;
  }
  nodes.forEach((n) => n.el.addEventListener('click', () => rename(n, FF.still)));

  // Distance from the title: files arrive from the middle outwards, and are renamed in that order too.
  const title = document.querySelector('.title').getBoundingClientRect();
  const cx = title.left + title.width / 2, cy = title.top + title.height / 2;
  nodes.forEach((n) => {
    const r = n.el.getBoundingClientRect();
    n.dist = Math.hypot(r.left + r.width / 2 - cx, (r.top + r.height / 2 - cy) * 1.3);
    n.el.style.setProperty('--d', `${Math.round(n.dist * 0.45)}ms`);
  });

  // Only while the folder is on screen: nobody needs files renaming themselves out of sight.
  let seen = true;
  new IntersectionObserver(([e]) => { seen = e.isIntersecting; }).observe(grid);
  async function wander() {
    await FF.sleep(1800);
    for (;;) {
      if (!seen) { await FF.sleep(500); continue; }
      const left = nodes.filter((n) => !n.done && !n.busy && n.el.offsetParent).sort((p, q) => p.dist - q.dist);
      if (!left.length) return;
      await rename(left[Math.floor(Math.random() * Math.min(3, left.length))], false);
      await FF.sleep(1100);
    }
  }
  if (!FF.still) wander();
})();
