(() => {
  // 1. Theme Toggle (persisted in localStorage)
  const root = document.documentElement;
  const themeBtn = document.getElementById("themeToggle");
  const themeIcon = themeBtn?.querySelector(".theme-icon");

  function applyTheme(mode) {
    root.setAttribute("data-theme", mode);
    localStorage.setItem("goclean-portal-theme", mode);
    if (themeIcon) themeIcon.textContent = mode === "dark" ? "☀︎" : "☾";
  }

  const savedTheme = localStorage.getItem("goclean-portal-theme") || "dark";
  applyTheme(savedTheme);

  themeBtn?.addEventListener("click", () => {
    const next = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
    applyTheme(next);
  });

  // 2. Scroll Reveal Animations + Animated Metric Counters
  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("visible");
        const counter = entry.target.querySelector(".metric-num[data-count]");
        if (counter && !counter.dataset.animated) {
          counter.dataset.animated = "1";
          animateCounter(counter);
        }
        revealObserver.unobserve(entry.target);
      });
    },
    { threshold: 0.15 }
  );

  document.querySelectorAll(".reveal").forEach((el) => revealObserver.observe(el));

  function animateCounter(el) {
    const target = Number(el.dataset.count || 0);
    const suffix = el.dataset.suffix || "";
    const duration = 900;
    const start = performance.now();
    function tick(now) {
      const p = Math.min(1, (now - start) / duration);
      const eased = 1 - Math.pow(1 - p, 3);
      el.textContent = `${Math.round(target * eased)}${suffix}`;
      if (p < 1) requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  // 3. Interactive Hero Luminous Orbital Map Canvas
  const canvas = document.getElementById("orbitalCanvas");
  const hubSize = document.getElementById("hubSize");
  const hubName = document.getElementById("hubName");
  const hubShare = document.getElementById("hubShare");
  const hubEl = document.getElementById("orbitalHub");
  const legendEl = document.getElementById("orbitalLegend");

  const slices = [
    { name: "Developer", gb: 106.2, pct: 34.0, color: "#14c8cc", sub: [0.46, 0.34, 0.20] },
    { name: "Applications", gb: 81.4, pct: 26.1, color: "#6366f1", sub: [0.58, 0.42] },
    { name: "Movies & 4K", gb: 59.8, pct: 19.1, color: "#f43f5e", sub: [0.65, 0.35] },
    { name: "Caches", gb: 34.1, pct: 10.9, color: "#a855f7", sub: [0.55, 0.45] },
    { name: "Downloads", gb: 19.5, pct: 6.2, color: "#f59e0b", sub: [1.0] },
    { name: "Documents", gb: 11.4, pct: 3.7, color: "#10b981", sub: [1.0] }
  ];

  let hoveredIdx = -1;
  let sweepProgress = 0;

  if (legendEl) {
    slices.forEach((s, idx) => {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "legend-chip";
      chip.style.setProperty("--chip-color", s.color);
      chip.innerHTML = `<span class="legend-dot"></span><span>${s.name}</span><span class="legend-val">${s.gb}G</span>`;
      chip.addEventListener("mouseenter", () => setHovered(idx));
      chip.addEventListener("mouseleave", () => setHovered(-1));
      chip.addEventListener("click", () => setHovered(hoveredIdx === idx ? -1 : idx));
      legendEl.appendChild(chip);
    });
  }

  function setHovered(idx) {
    hoveredIdx = idx;
    document.querySelectorAll(".legend-chip").forEach((el, i) => {
      el.classList.toggle("active", i === idx);
    });
    if (idx >= 0) {
      const s = slices[idx];
      hubSize.textContent = `${s.gb.toFixed(1)} GB`;
      hubName.textContent = s.name;
      hubShare.textContent = `${s.pct.toFixed(1)}% of disk`;
      hubShare.style.color = s.color;
      hubEl.style.borderColor = s.color;
    } else {
      hubSize.textContent = "312.4 GB";
      hubName.textContent = "Macintosh HD";
      hubShare.textContent = "Hover a slice";
      hubShare.style.color = "";
      hubEl.style.borderColor = "rgba(20, 200, 204, 0.45)";
    }
  }

  if (canvas) {
    const ctx = canvas.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    const size = 460;
    canvas.width = size * dpr;
    canvas.height = size * dpr;
    ctx.scale(dpr, dpr);

    const cx = size / 2;
    const cy = size / 2;
    const maxR = size * 0.45;
    const computedAngles = [];

    let acc = 0;
    slices.forEach((s) => {
      const span = (s.pct / 100) * Math.PI * 2;
      computedAngles.push({ start: acc, end: acc + span });
      acc += span;
    });

    function drawOrbital() {
      ctx.clearRect(0, 0, size, size);
      sweepProgress = Math.min(1, sweepProgress + 0.032);
      const easedSweep = 1 - Math.pow(1 - sweepProgress, 3);
      const maxAngle = easedSweep * Math.PI * 2;

      // Subtle guide rings
      [0.36, 0.62, 0.84, 0.98].forEach((ratio) => {
        ctx.beginPath();
        ctx.arc(cx, cy, maxR * ratio, 0, Math.PI * 2);
        ctx.strokeStyle = "rgba(148, 163, 184, 0.12)";
        ctx.lineWidth = 1;
        ctx.stroke();
      });

      slices.forEach((s, idx) => {
        const { start, end } = computedAngles[idx];
        const clampedEnd = Math.min(end, maxAngle);
        if (clampedEnd <= start + 0.01) return;

        const isHover = idx === hoveredIdx;
        const gap = 0.022;
        const a0 = start - Math.PI / 2 + gap / 2;
        const a1 = clampedEnd - Math.PI / 2 - gap / 2;
        if (a1 <= a0) return;

        const rIn = maxR * 0.38;
        const rOut = maxR * 0.65 + (isHover ? 9 : 0);

        ctx.save();
        ctx.beginPath();
        ctx.arc(cx, cy, rOut, a0, a1);
        ctx.arc(cx, cy, rIn, a1, a0, true);
        ctx.closePath();

        if (isHover) {
          ctx.shadowColor = s.color;
          ctx.shadowBlur = 22;
        }
        ctx.globalAlpha = hoveredIdx === -1 || isHover ? 0.94 : 0.48;
        ctx.fillStyle = s.color;
        ctx.fill();
        ctx.restore();

        // Outer sub-ring
        let subCursor = a0;
        const subSpan = a1 - a0;
        s.sub.forEach((frac, si) => {
          const sa1 = subCursor + subSpan * frac - 0.014;
          if (sa1 <= subCursor) return;
          ctx.save();
          ctx.beginPath();
          ctx.arc(cx, cy, maxR * 0.88 + (isHover ? 6 : 0), subCursor, sa1);
          ctx.arc(cx, cy, maxR * 0.68 + (isHover ? 6 : 0), sa1, subCursor, true);
          ctx.closePath();
          ctx.globalAlpha = (hoveredIdx === -1 || isHover ? 0.66 : 0.28) - si * 0.08;
          ctx.fillStyle = s.color;
          ctx.fill();
          ctx.restore();
          subCursor = sa1 + 0.014;
        });
      });

      requestAnimationFrame(drawOrbital);
    }

    requestAnimationFrame(drawOrbital);

    canvas.addEventListener("mousemove", (e) => {
      const rect = canvas.getBoundingClientRect();
      const x = ((e.clientX - rect.left) / rect.width) * size - cx;
      const y = ((e.clientY - rect.top) / rect.height) * size - cy;
      const dist = Math.hypot(x, y);
      if (dist < maxR * 0.36 || dist > maxR * 0.95) {
        setHovered(-1);
        return;
      }
      let angle = Math.atan2(y, x) + Math.PI / 2;
      if (angle < 0) angle += Math.PI * 2;
      const found = computedAngles.findIndex((a) => angle >= a.start && angle <= a.end);
      setHovered(found);
    });

    canvas.addEventListener("mouseleave", () => setHovered(-1));
  }

  // 4. Screenshot Gallery Tabs + Lightbox
  const screenshots = [
    {
      src: "screenshots/01-orbital-map.png",
      title: "Luminous Orbital Map & Bidirectional Inspector",
      desc: "Switch effortlessly between Orbital Map, Treemap, and Tree List views. Hovering any slice highlights the inspector row, shows physical APFS allocation, and lets you preview with Quick Look or stage in one click."
    },
    {
      src: "screenshots/02-smart-cleanup.png",
      title: "Smart Cleanup Buckets with Safe / Danger Badges & Collector Dock",
      desc: "Find dormant node_modules, Xcode DerivedData, Rust target/, and orphaned app leftovers. No-impact files are badged Safe while system assets are flagged Danger and guarded by SafetyGuard."
    },
    {
      src: "screenshots/03-applications.png",
      title: "Unified Application Manager — App Store, Homebrew & Curl CLIs",
      desc: "See every app's true footprint including ~/Library leftovers, detect Homebrew reverse dependencies before uninstalling, and run brew uninstall --cask --zap or deep Trash removal cleanly."
    },
    {
      src: "screenshots/04-overview-light.png",
      title: "Daylight Frosted Glass — Full Dark, Light & System Mode Parity",
      desc: "Switch instantly between Dark, Light, and Auto macOS appearance. Live storage telemetry rings and Smart Cleanup cards give you an instant snapshot of your Mac's health."
    }
  ];

  const galleryImg = document.getElementById("galleryImg");
  const galleryTitle = document.getElementById("galleryTitle");
  const galleryDesc = document.getElementById("galleryDesc");
  const galleryDots = document.getElementById("galleryDots");
  const tabBtns = document.querySelectorAll(".tab-btn");
  let activeShot = 0;

  if (galleryDots) {
    screenshots.forEach((_, i) => {
      const dot = document.createElement("span");
      dot.className = `g-dot ${i === 0 ? "active" : ""}`;
      galleryDots.appendChild(dot);
    });
  }

  function showShot(idx) {
    activeShot = idx;
    const item = screenshots[idx];
    tabBtns.forEach((b, i) => {
      const active = i === idx;
      b.classList.toggle("active", active);
      b.setAttribute("aria-selected", String(active));
    });
    document.querySelectorAll(".g-dot").forEach((d, i) => d.classList.toggle("active", i === idx));

    galleryImg.classList.add("fading");
    setTimeout(() => {
      galleryImg.src = item.src;
      galleryImg.alt = item.title;
      galleryTitle.textContent = item.title;
      galleryDesc.textContent = item.desc;
      galleryImg.classList.remove("fading");
    }, 150);
  }

  tabBtns.forEach((btn) => {
    btn.addEventListener("click", () => showShot(Number(btn.dataset.shot)));
  });

  // Lightbox
  const lightbox = document.getElementById("lightbox");
  const lightboxImg = document.getElementById("lightboxImg");
  const zoomBtn = document.getElementById("zoomBtn");
  const lightboxClose = document.getElementById("lightboxClose");

  function openLightbox() {
    lightboxImg.src = screenshots[activeShot].src;
    lightbox.hidden = false;
  }
  function closeLightbox() { lightbox.hidden = true; }

  zoomBtn?.addEventListener("click", openLightbox);
  galleryImg?.addEventListener("click", openLightbox);
  lightboxClose?.addEventListener("click", closeLightbox);
  lightbox?.addEventListener("click", (e) => { if (e.target === lightbox) closeLightbox(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeLightbox(); });

  // 5. Copy Quick Start Commands
  const copyBtn = document.getElementById("copyCmdBtn");
  const codeEl = document.getElementById("quickStartCode");
  copyBtn?.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(codeEl.textContent.trim());
      copyBtn.textContent = "✓ Copied!";
      setTimeout(() => (copyBtn.textContent = "Copy Commands"), 1800);
    } catch {
      copyBtn.textContent = "Select & Copy";
    }
  });
})();
