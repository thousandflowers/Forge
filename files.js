// Shared by the directions: how a file is drawn, and how a name is retyped.
(() => {
  const GOOSE = { src: 'media/files/goose.jpg', ar: 1.5 };
  const BAND = { PDF: '#D7352B', MD: '#56616D', TXT: '#56616D', DOCX: '#2D6BD2', M4A: '#B64AD0', WAV: '#B64AD0' };
  const SOUND = new Set(['M4A', 'WAV']);

  const page = (ext) => {
    const c = BAND[ext];
    const body = SOUND.has(ext)
      ? [10, 22, 34, 18, 40, 26, 34, 14].map((h, i) => `<rect x="${25 + i * 6.2}" y="${50 - h / 2}" width="3.6" height="${h}" rx="1.8" fill="${c}"/>`).join('')
      : [34, 42, 50, 58].map((y, i) => `<rect x="26" y="${y}" width="${[46, 40, 46, 28][i]}" height="4" rx="2" fill="#CBD1D9"/>`).join('');
    return `<svg class="ff-page" viewBox="0 0 100 100" role="img" aria-label="${ext} file"><path d="M22 4h40l20 20v66a6 6 0 0 1-6 6H22a6 6 0 0 1-6-6V10a6 6 0 0 1 6-6z" fill="#fff"/><path d="M62 4v14a6 6 0 0 0 6 6h14z" fill="#D9DDE3"/>${body}<rect x="16" y="72" width="66" height="18" fill="${c}"/><text x="49" y="86" text-anchor="middle" font-family="-apple-system,system-ui,sans-serif" font-weight="800" font-size="13.5" fill="#fff">${ext}</text></svg>`;
  };

  // A picture keeps its own shape, the way the Finder draws a thumbnail: wide ones fill the width, tall ones the height.
  const picture = (cls, o) => {
    const im = o.img || GOOSE, ar = cls.includes('is-square') ? 1 : im.ar;
    const w = ar >= 1 ? 88 : Math.round(88 * ar);
    return `<div class="ff-photo ${cls}" style="--ar:${ar};width:${w}%"><img src="${im.src}" alt="" loading="lazy">${cls.includes('ff-film') ? '<svg viewBox="0 0 100 70" preserveAspectRatio="xMidYMid meet"><circle cx="50" cy="35" r="12" fill="#000" opacity=".55"/><path d="M46 29l11 6-11 6z" fill="#fff"/></svg>' : ''}</div>`;
  };
  const scan = (cls) => `<div class="ff-photo ff-scan ${cls}" style="--ar:1.43;width:88%"><div class="ff-sheet">Honk if you<br>can read this</div></div>`;

  // A kind is a word for how the file looks right now.
  const DRAW = {
    md: () => page('MD'), pdf: () => page('PDF'), txt: () => page('TXT'), docx: () => page('DOCX'),
    m4a: () => page('M4A'), wav: () => page('WAV'),
    photo: (o) => picture('', o), gray: (o) => picture('is-gray', o), round: (o) => picture('is-round', o), square: (o) => picture('is-square', o),
    film: (o) => picture('ff-film', o), gif: (o) => picture('ff-film is-gif', o),
    scan: () => scan(''), scanned: () => scan('is-straight'),
  };

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // What stays, what goes, what is typed: holiday.jpg -> holiday_2MB.jpg keeps "holiday" and ".jpg".
  const split = (a, b) => {
    let p = 0;
    while (p < a.length && p < b.length && a[p] === b[p]) p++;
    let s = 0;
    while (s < a.length - p && s < b.length - p && a[a.length - 1 - s] === b[b.length - 1 - s]) s++;
    return { pre: a.slice(0, p), oldMid: a.slice(p, a.length - s), newMid: b.slice(p, b.length - s), suf: a.slice(a.length - s) };
  };

  // render(pre, mid, suf, mode): mode 'sel' = mid is selected, 'type' = mid is being typed.
  const retype = async (a, b, render, speed = 75) => {
    const { pre, oldMid, newMid, suf } = split(a, b);
    render(pre, oldMid, suf, 'sel');
    await sleep(oldMid ? 520 : 260);
    for (let i = 1; i <= newMid.length; i++) {
      render(pre, newMid.slice(0, i), suf, 'type');
      await sleep(speed);
    }
  };

  window.FF = { draw: (kind, o = {}) => DRAW[kind](o), sleep, split, retype, still: matchMedia('(prefers-reduced-motion: reduce)').matches };
})();
