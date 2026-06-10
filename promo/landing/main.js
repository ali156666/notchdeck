(() => {
  const root = document.documentElement;
  const reducedMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  const story = document.querySelector(".story");
  const storyDots = Array.from(document.querySelectorAll(".story-dot"));
  const storyPanels = Array.from(document.querySelectorAll(".story-panel"));
  const storyShots = Array.from(document.querySelectorAll(".story-shot"));
  const mobileSteps = Array.from(document.querySelectorAll(".mobile-step"));
  const stepCount = storyPanels.length;

  const setActiveStep = (nextIndex) => {
    const activeIndex = Math.max(0, Math.min(stepCount - 1, nextIndex));
    storyPanels.forEach((panel, index) => panel.classList.toggle("is-active", index === activeIndex));
    storyShots.forEach((shot, index) => shot.classList.toggle("is-active", index === activeIndex));
    storyDots.forEach((dot, index) => dot.classList.toggle("is-active", index === activeIndex));
  };

  const scrollToStep = (index) => {
    if (!story) {
      return;
    }

    const storyTop = story.getBoundingClientRect().top + window.scrollY;
    const desktopRange = window.innerHeight * 4.1;
    const progress = stepCount <= 1 ? 0 : index / (stepCount - 1);
    window.scrollTo({
      top: storyTop + desktopRange * progress,
      behavior: reducedMotionQuery.matches ? "auto" : "smooth",
    });
  };

  storyDots.forEach((dot) => {
    dot.addEventListener("click", () => {
      const targetStep = Number(dot.dataset.targetStep || 0);
      scrollToStep(targetStep);
    });
  });

  if (!window.gsap || !window.ScrollTrigger) {
    root.classList.add("no-gsap");
    setActiveStep(0);
    return;
  }

  const { gsap, ScrollTrigger } = window;
  gsap.registerPlugin(ScrollTrigger);
  gsap.defaults({ duration: 0.72, ease: "power3.out", overwrite: "auto" });

  if (reducedMotionQuery.matches) {
    root.classList.add("reduced-motion");
    setActiveStep(0);
    return;
  }

  const mm = gsap.matchMedia();

  mm.add("(min-width: 981px)", () => {
    const heroTimeline = gsap.timeline({ defaults: { ease: "power3.out" } });
    heroTimeline
      .from(".brand-lockup", { autoAlpha: 0, y: -12, duration: 0.55 }, 0)
      .from(".site-nav", { autoAlpha: 0, y: -12, duration: 0.55 }, 0.08)
      .from(".hero-title span", { autoAlpha: 0, y: 34, stagger: 0.09, duration: 0.82 }, 0.12)
      .from(".hero-copy", { autoAlpha: 0, y: 22, duration: 0.66 }, 0.4)
      .from(".hero-actions a", { autoAlpha: 0, y: 16, stagger: 0.07, duration: 0.48 }, 0.54)
      .from(".hero-stage", { autoAlpha: 0, y: 28, scale: 0.96, duration: 0.86 }, 0.58);

    gsap.set(storyPanels.slice(1), { autoAlpha: 0, y: 28 });
    gsap.set(storyShots.slice(1), { autoAlpha: 0, y: 34, scale: 0.965 });
    gsap.set(storyPanels[0], { autoAlpha: 1, y: 0 });
    gsap.set(storyShots[0], { autoAlpha: 1, y: 0, scale: 1 });

    const storyTimeline = gsap.timeline({
      defaults: { ease: "power3.inOut" },
      scrollTrigger: {
        trigger: story,
        start: "top top",
        end: () => `+=${window.innerHeight * 4.1}`,
        scrub: 0.72,
        pin: ".story-pin",
        anticipatePin: 1,
        invalidateOnRefresh: true,
        onUpdate: (self) => {
          const nextIndex = Math.round(self.progress * (stepCount - 1));
          setActiveStep(nextIndex);
        },
      },
    });

    storyPanels.forEach((panel, index) => {
      storyTimeline.addLabel(`step-${index}`, index);
      if (index === 0) {
        storyTimeline.to(storyShots[index], { y: -10, duration: 0.8, ease: "none" }, index + 0.12);
        return;
      }

      const previousPanel = storyPanels[index - 1];
      const previousShot = storyShots[index - 1];
      const shot = storyShots[index];

      storyTimeline
        .to(previousPanel, { autoAlpha: 0, y: -28, duration: 0.28 }, index - 0.16)
        .to(previousShot, { autoAlpha: 0, y: -34, scale: 0.97, duration: 0.32 }, index - 0.16)
        .fromTo(panel, { autoAlpha: 0, y: 30 }, { autoAlpha: 1, y: 0, duration: 0.36 }, index + 0.02)
        .fromTo(shot, { autoAlpha: 0, y: 38, scale: 0.965 }, { autoAlpha: 1, y: 0, scale: 1, duration: 0.42 }, index + 0.02)
        .to(shot, { y: -12, duration: 0.72, ease: "none" }, index + 0.34);
    });

    storyTimeline.to({}, { duration: 0.85 });

    gsap.from(".closing-inner", {
      autoAlpha: 0,
      y: 32,
      scrollTrigger: {
        trigger: ".closing",
        start: "top 74%",
        toggleActions: "play none none reverse",
      },
    });

    gsap.from(".more-inner > .eyebrow, .more-inner > h2", {
      autoAlpha: 0,
      y: 24,
      stagger: 0.08,
      scrollTrigger: {
        trigger: ".more-features",
        start: "top 76%",
        toggleActions: "play none none reverse",
      },
    });

    gsap.from(".feature-row", {
      autoAlpha: 0,
      y: 38,
      stagger: 0.12,
      scrollTrigger: {
        trigger: ".feature-stack",
        start: "top 78%",
        toggleActions: "play none none reverse",
      },
    });

    return () => {
      heroTimeline.kill();
    };
  });

  mm.add("(max-width: 980px)", () => {
    const heroTimeline = gsap.timeline({ defaults: { ease: "power3.out" } });
    heroTimeline
      .from(".site-header", { autoAlpha: 0, y: -10, duration: 0.42 }, 0)
      .from(".hero-title span", { autoAlpha: 0, y: 26, stagger: 0.08, duration: 0.7 }, 0.1)
      .from(".hero-copy", { autoAlpha: 0, y: 18, duration: 0.56 }, 0.28)
      .from(".hero-actions a", { autoAlpha: 0, y: 14, stagger: 0.06, duration: 0.44 }, 0.4)
      .from(".hero-stage", { autoAlpha: 0, y: 22, scale: 0.97, duration: 0.68 }, 0.46);

    mobileSteps.forEach((step) => {
      gsap.from(step, {
        autoAlpha: 0,
        y: 34,
        scrollTrigger: {
          trigger: step,
          start: "top 82%",
          toggleActions: "play none none reverse",
        },
      });
    });

    gsap.from(".closing-inner", {
      autoAlpha: 0,
      y: 28,
      scrollTrigger: {
        trigger: ".closing",
        start: "top 82%",
        toggleActions: "play none none reverse",
      },
    });

    gsap.from(".feature-row", {
      autoAlpha: 0,
      y: 30,
      stagger: 0.08,
      scrollTrigger: {
        trigger: ".feature-stack",
        start: "top 82%",
        toggleActions: "play none none reverse",
      },
    });

    return () => {
      heroTimeline.kill();
    };
  });

  window.addEventListener("load", () => {
    ScrollTrigger.refresh();
  });
})();

/* 漂浮粒子：iOS 风柔光气泡 + 指针视差（多区域，强度可配） */
(() => {
  const heroCanvas = document.querySelector(".hero-particles");
  const pageCanvas = document.querySelector(".page-particles");
  const closingCanvas = document.querySelector(".closing-particles");
  if (!heroCanvas && !pageCanvas && !closingCanvas) {
    return;
  }

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const rand = (min, max) => min + Math.random() * (max - min);

  const COLORS = [
    [52, 120, 246],
    [41, 200, 105],
    [245, 165, 36],
    [90, 150, 250],
  ];

  const sprites = COLORS.map((rgb) => {
    const size = 64;
    const sprite = document.createElement("canvas");
    sprite.width = sprite.height = size;
    const sctx = sprite.getContext("2d");
    const gradient = sctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    gradient.addColorStop(0, `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, 0.95)`);
    gradient.addColorStop(0.45, `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, 0.42)`);
    gradient.addColorStop(1, `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, 0)`);
    sctx.fillStyle = gradient;
    sctx.fillRect(0, 0, size, size);
    return sprite;
  });

  const pointer = { vx: 0, vy: 0, hasPos: false };
  const fields = [];

  const createField = (canvas, options) => {
    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) {
      return null;
    }
    const settings = {
      density: 26000,
      minCount: 10,
      maxCount: 56,
      alphaScale: 1,
      reach: 150,
      fixed: false,
    };
    Object.assign(settings, options);

    const host = settings.fixed ? null : canvas.closest("section") || canvas.parentElement;
    let particles = [];
    let width = 0;
    let height = 0;

    const build = () => {
      const count = Math.round(
        Math.min(settings.maxCount, Math.max(settings.minCount, (width * height) / settings.density))
      );
      particles = [];
      for (let i = 0; i < count; i += 1) {
        particles.push({
          x: Math.random() * width,
          y: Math.random() * height,
          radius: rand(6, 17),
          colorIndex: Math.floor(Math.random() * COLORS.length),
          speedX: rand(-0.12, 0.12),
          speedY: rand(-0.4, -0.12),
          drift: Math.random() * Math.PI * 2,
          driftSpeed: rand(0.003, 0.008),
          driftAmp: rand(0.1, 0.35),
          twinkle: Math.random() * Math.PI * 2,
          twinkleSpeed: rand(0.006, 0.015),
          baseAlpha: rand(0.12, 0.34),
        });
      }
    };

    const resize = () => {
      if (settings.fixed) {
        width = window.innerWidth;
        height = window.innerHeight;
      } else {
        const rect = canvas.getBoundingClientRect();
        width = rect.width;
        height = rect.height;
      }
      if (width <= 0 || height <= 0) {
        return;
      }
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      build();
    };

    const draw = () => {
      if (width <= 0 || height <= 0) {
        return;
      }
      ctx.clearRect(0, 0, width, height);

      let px = 0;
      let py = 0;
      let pointerActive = false;
      if (pointer.hasPos) {
        if (settings.fixed) {
          px = pointer.vx;
          py = pointer.vy;
        } else {
          const rect = canvas.getBoundingClientRect();
          px = pointer.vx - rect.left;
          py = pointer.vy - rect.top;
        }
        pointerActive = px >= -60 && px <= width + 60 && py >= -60 && py <= height + 60;
      }

      for (let i = 0; i < particles.length; i += 1) {
        const p = particles[i];
        p.drift += p.driftSpeed;
        p.twinkle += p.twinkleSpeed;
        p.x += p.speedX + Math.cos(p.drift) * p.driftAmp;
        p.y += p.speedY;

        if (pointerActive) {
          const dx = p.x - px;
          const dy = p.y - py;
          const distSq = dx * dx + dy * dy;
          const reach = settings.reach;
          if (distSq < reach * reach) {
            const dist = Math.sqrt(distSq) || 1;
            const push = (1 - dist / reach) * 1.6;
            p.x += (dx / dist) * push;
            p.y += (dy / dist) * push;
          }
        }

        if (p.y + p.radius < -24) {
          p.y = height + p.radius + 12;
          p.x = Math.random() * width;
        }
        if (p.x < -40) {
          p.x = width + 40;
        } else if (p.x > width + 40) {
          p.x = -40;
        }

        const alpha = p.baseAlpha * (0.55 + 0.45 * Math.sin(p.twinkle)) * settings.alphaScale;
        const drawSize = p.radius * 2;
        ctx.globalAlpha = alpha > 0 ? alpha : 0;
        ctx.drawImage(sprites[p.colorIndex], p.x - p.radius, p.y - p.radius, drawSize, drawSize);
      }
      ctx.globalAlpha = 1;
    };

    const clear = () => {
      if (width > 0 && height > 0) {
        ctx.clearRect(0, 0, width, height);
      }
    };

    return { host, fixed: settings.fixed, running: false, resize, draw, clear };
  };

  if (pageCanvas) {
    const field = createField(pageCanvas, {
      density: 54000,
      minCount: 12,
      maxCount: 42,
      alphaScale: 0.5,
      reach: 130,
      fixed: true,
    });
    if (field) {
      fields.push(field);
    }
  }
  if (heroCanvas) {
    const field = createField(heroCanvas, { density: 26000, maxCount: 56 });
    if (field) {
      fields.push(field);
    }
  }
  if (closingCanvas) {
    const field = createField(closingCanvas, { density: 26000, maxCount: 48 });
    if (field) {
      fields.push(field);
    }
  }

  if (!fields.length) {
    return;
  }

  let rafId = 0;
  let looping = false;

  const loop = () => {
    let active = false;
    for (let i = 0; i < fields.length; i += 1) {
      if (fields[i].running) {
        fields[i].draw();
        active = true;
      }
    }
    if (active && !reducedMotion.matches) {
      rafId = window.requestAnimationFrame(loop);
    } else {
      looping = false;
    }
  };

  const ensureLoop = () => {
    if (!looping && !reducedMotion.matches && fields.some((field) => field.running)) {
      looping = true;
      rafId = window.requestAnimationFrame(loop);
    }
  };

  const startField = (field) => {
    if (reducedMotion.matches) {
      return;
    }
    field.running = true;
    ensureLoop();
  };

  const stopField = (field) => {
    field.running = false;
    field.clear();
  };

  const resizeAll = () => {
    for (let i = 0; i < fields.length; i += 1) {
      fields[i].resize();
    }
  };

  let resizeTimer = 0;
  window.addEventListener("resize", () => {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(resizeAll, 180);
  });

  window.addEventListener(
    "pointermove",
    (event) => {
      pointer.vx = event.clientX;
      pointer.vy = event.clientY;
      pointer.hasPos = true;
    },
    { passive: true }
  );

  window.addEventListener("blur", () => {
    pointer.hasPos = false;
  });

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      window.cancelAnimationFrame(rafId);
      looping = false;
    } else {
      ensureLoop();
    }
  });

  const handleMotionChange = () => {
    if (reducedMotion.matches) {
      window.cancelAnimationFrame(rafId);
      looping = false;
      for (let i = 0; i < fields.length; i += 1) {
        fields[i].running = false;
        fields[i].clear();
      }
    } else {
      resizeAll();
      for (let i = 0; i < fields.length; i += 1) {
        if (fields[i].fixed) {
          startField(fields[i]);
        }
      }
    }
  };
  if (typeof reducedMotion.addEventListener === "function") {
    reducedMotion.addEventListener("change", handleMotionChange);
  }

  resizeAll();

  for (let i = 0; i < fields.length; i += 1) {
    const field = fields[i];
    if (field.fixed) {
      startField(field);
    } else if (field.host && "IntersectionObserver" in window) {
      const observer = new IntersectionObserver(
        (entries) => {
          for (let e = 0; e < entries.length; e += 1) {
            if (entries[e].isIntersecting) {
              startField(field);
            } else {
              stopField(field);
            }
          }
        },
        { threshold: 0 }
      );
      observer.observe(field.host);
    } else {
      startField(field);
    }
  }
})();
