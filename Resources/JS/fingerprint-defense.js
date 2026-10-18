/*
 * Icy Weasel — fingerprinting defence.
 *
 * SCOPE is set by measurement (FingerprintSurfaceProbe), not habit. Stock
 * WebKit already caps hardwareConcurrency, returns the spec-standard plugin
 * list, masks the WebGL renderer and hides local IPs behind mDNS; patching any
 * of those would only make this browser more distinctive. What it leaves
 * exposed is high-entropy READBACK — canvas pixels and audio samples — and
 * that is all this script touches.
 *
 * INVARIANTS (each has a test):
 *  - Noise is a pure function of (partition seed, pixel/sample position). The
 *    seed is derived in Swift from a per-launch secret and the TOP-LEVEL site,
 *    so every frame on a page agrees, and a tracker embedded on two sites sees
 *    two different values.
 *  - Noise is idempotent: applying it twice equals applying it once, so a
 *    realm patched by two script instances still returns consistent values.
 *  - Blank canvases and silent audio are never perturbed.
 *  - Readback never alters what the page drew or plays.
 *  - Patched functions match native toString/name/length/descriptors, no
 *    globals are added, and Proxy handlers have null prototypes.
 *  - Same-origin child frames are patched before the page can reach them, so
 *    borrowing a pristine prototype from a fresh iframe does not work.
 *
 * KNOWN LIMITS: runs in the page world, so a determined adversary can detect
 * it through side channels (error stack shapes, timing). OffscreenCanvas used
 * inside a Web Worker is not covered — workers never receive user scripts.
 */
(function () {
  "use strict";

  // --- Primordials ------------------------------------------------------------
  // Trap code runs long after page scripts start. Anything looked up at call
  // time (WeakMap.prototype.get, Math.imul...) could by then be a page-supplied
  // spy that receives this script's private objects — including the map from
  // disguised proxies back to pristine natives.
  const ReflectApply = Reflect.apply;
  const ProxyCtor = Proxy;
  const defineProperty = Object.defineProperty;
  const getOwnPropertyDescriptor = Object.getOwnPropertyDescriptor;
  const getPrototypeOf = Object.getPrototypeOf;
  const mapGet = WeakMap.prototype.get;
  const mapSet = WeakMap.prototype.set;
  const setHas = WeakSet.prototype.has;
  const setAdd = WeakSet.prototype.add;
  const imul = Math.imul;
  const trunc = Math.trunc;
  const round = Math.round;
  const toNumber = Number;
  const isView = ArrayBuffer.isView;
  const stringIndexOf = String.prototype.indexOf;
  const typedLength = getOwnPropertyDescriptor(getPrototypeOf(Uint8Array.prototype), "length").get;
  const nativeFunctionToString = Function.prototype.toString;
  // uncurry(fn)(thisArg, ...args) === fn.call(thisArg, ...args), through a bound
  // function whose target was captured here. No per-call array allocation and
  // nothing a page can intercept — this is what keeps DOM hooks cheap.
  const functionCall = Function.prototype.call;
  const functionBind = Function.prototype.bind;
  function uncurry(fn) { return ReflectApply(functionBind, functionCall, [fn]); }
  const weakSetHas = uncurry(WeakSet.prototype.has);
  const weakSetAdd = uncurry(WeakSet.prototype.add);

  const disguised = new WeakMap();   // proxy -> the function it stands in for
  const patchedRealms = new WeakSet(); // keyed by each realm's Function.prototype
  // Every child WindowProxy already handled, same- or cross-origin. A proxy
  // is stable across navigations, and any later document in that frame is a
  // real navigation that receives this script natively, so one visit is enough.
  // It also spares cross-origin frames an exception on every DOM insertion.
  const handledWindows = new WeakSet();

  // Swift substitutes a per-launch, per-top-level-site value here.
  const SEED = __IW_SEED__ >>> 0;

  function mix(a, b) {
    let h = imul(a ^ b ^ 0x9e3779b9, 0x85ebca6b);
    h = imul(h ^ (h >>> 13), 0xc2b2ae35);
    return (h ^ (h >>> 16)) >>> 0;
  }

  // --- Idempotent noise ---------------------------------------------------------
  // Canvas: on ~1/8 of opaque pixels, force one channel's low bit to a hashed
  // value. Forcing (rather than adding) is what makes a second application a
  // no-op. `bottomUpHeight` maps WebGL's bottom-left row order onto canvas rows
  // so readPixels and toDataURL of one canvas perturb the same pixels.
  function noisePixels(data, width, originX, originY, bottomUpHeight) {
    const length = ReflectApply(typedLength, data, []);
    const rows = width > 0 ? trunc(length / 4 / width) : 0;
    const flipped = bottomUpHeight !== undefined;
    for (let row = 0; row < rows; row++) {
      const canvasRow = flipped ? bottomUpHeight - 1 - originY - row : originY + row;
      const rowSeed = mix(SEED, canvasRow | 0);
      const base = row * width * 4;
      for (let col = 0; col < width; col++) {
        const i = base + col * 4;
        if (data[i + 3] === 0) continue;
        const h = mix(rowSeed, (originX + col) | 0);
        if ((h & 7) !== 0) continue;
        const c = i + ((h >>> 3) % 3);
        data[c] = (data[c] & 0xfe) | ((h >>> 5) & 1);
      }
    }
  }

  // Audio: snap to a 2e-6 grid, then offset by ±5e-7. f(f(x)) === f(x) because
  // the offset is a quarter step and rounds away on re-application. Peak change
  // is 1.5e-6 (about -116 dBFS): inaudible, but it moves any full-precision sum.
  const AUDIO_STEP = 2e-6;
  const AUDIO_OFFSET = AUDIO_STEP / 4;
  function noiseSamples(data, salt) {
    const length = ReflectApply(typedLength, data, []);
    const channelSeed = mix(SEED ^ 0xa5a5a5a5, salt | 0);
    for (let i = 0; i < length; i++) {
      const v = data[i];
      if (v === 0 || v !== v || v === Infinity || v === -Infinity) continue;
      const h = mix(channelSeed, i);
      if ((h & 15) !== 0) continue;
      data[i] = round(v / AUDIO_STEP) * AUDIO_STEP + ((h >>> 4) & 1 ? AUDIO_OFFSET : -AUDIO_OFFSET);
    }
  }

  // --- Seamless patching ----------------------------------------------------------
  function disguise(proxy, original) { ReflectApply(mapSet, disguised, [proxy, original]); }

  function isAlreadyProxied(fn) {
    try {
      const text = ReflectApply(nativeFunctionToString, fn, []);
      return ReflectApply(stringIndexOf, text, ["ProxyObject"]) !== -1;
    } catch (e) { return false; }
  }

  // Null-prototype handlers: an inherited trap lookup would let a page install
  // e.g. Object.prototype.getPrototypeOf and receive the native target.
  function wrap(target, trap) {
    const proxy = new ProxyCtor(target, { __proto__: null, apply: trap });
    disguise(proxy, target);
    return proxy;
  }

  function patchMethod(proto, key, trap) {
    if (!proto) return null;
    const desc = getOwnPropertyDescriptor(proto, key);
    if (!desc || typeof desc.value !== "function") return null;
    defineProperty(proto, key, {
      __proto__: null, value: wrap(desc.value, trap),
      writable: desc.writable, enumerable: desc.enumerable, configurable: desc.configurable
    });
    return desc.value;
  }

  function getter(proto, key) {
    const desc = proto && getOwnPropertyDescriptor(proto, key);
    return desc && desc.get;
  }

  // --- Realm installation --------------------------------------------------------
  function install(win) {
    if (weakSetHas(handledWindows, win)) return;
    weakSetAdd(handledWindows, win);
    let realmKey;
    try { realmKey = win.Function.prototype; } catch (e) { return; } // cross-origin
    if (ReflectApply(setHas, patchedRealms, [realmKey])) return;
    ReflectApply(setAdd, patchedRealms, [realmKey]);
    // A realm that received its own copy of this script natively is already
    // patched; noise is idempotent, but skipping avoids stacked traps.
    if (isAlreadyProxied(realmKey.toString)) return;

    // Function.prototype.toString answers with the original's source for any
    // disguised proxy — including itself.
    patchMethod(realmKey, "toString", function (target, self, args) {
      const original = ReflectApply(mapGet, disguised, [self]);
      return ReflectApply(target, original !== undefined ? original : self, args);
    });

    const C2D = win.CanvasRenderingContext2D && win.CanvasRenderingContext2D.prototype;
    const Canvas = win.HTMLCanvasElement && win.HTMLCanvasElement.prototype;
    const doc = win.document;
    const nativeGetImageData = C2D && C2D.getImageData;
    const nativePutImageData = C2D && C2D.putImageData;
    const nativeDrawImage = C2D && C2D.drawImage;
    const nativeGetContext = Canvas && Canvas.getContext;
    const nativeCreateElement = win.Document.prototype.createElement;
    const canvasWidth = getter(Canvas, "width");
    const canvasHeight = getter(Canvas, "height");
    const setCanvasWidth = Canvas && getOwnPropertyDescriptor(Canvas, "width").set;
    const setCanvasHeight = Canvas && getOwnPropertyDescriptor(Canvas, "height").set;
    const imageDataData = getter(win.ImageData && win.ImageData.prototype, "data");
    const imageDataWidth = getter(win.ImageData && win.ImageData.prototype, "width");

    // Canvas readback -----------------------------------------------------------
    if (C2D && nativeGetImageData) {
      patchMethod(C2D, "getImageData", function (target, self, args) {
        if (args.length < 4) return ReflectApply(target, self, args);
        // Coerce once, here, and hand native the primitives: a page passing an
        // object with valueOf must see it called exactly once, as natively.
        const sx = toNumber(args[0]), sy = toNumber(args[1]);
        const sw = toNumber(args[2]), sh = toNumber(args[3]);
        const forwarded = args.length > 4 ? [sx, sy, sw, sh, args[4]] : [sx, sy, sw, sh];
        const image = ReflectApply(target, self, forwarded);
        try {
          const x = trunc(sx) || 0, y = trunc(sy) || 0;
          noisePixels(ReflectApply(imageDataData, image, []), ReflectApply(imageDataWidth, image, []),
                      sw < 0 ? x + trunc(sw) : x, sh < 0 ? y + trunc(sh) : y);
        } catch (e) {}
        return image;
      });
    }

    // Exports encode a noised copy; the visible canvas is never written to and
    // never has a context created on it (which would lock out WebGL later).
    function noisedCopy(canvas) {
      const w = ReflectApply(canvasWidth, canvas, []), h = ReflectApply(canvasHeight, canvas, []);
      if (!(w > 0 && h > 0)) return null;
      const copy = ReflectApply(nativeCreateElement, doc, ["canvas"]);
      ReflectApply(setCanvasWidth, copy, [w]);
      ReflectApply(setCanvasHeight, copy, [h]);
      const ctx = ReflectApply(nativeGetContext, copy, ["2d"]);
      if (!ctx) return null;
      ReflectApply(nativeDrawImage, ctx, [canvas, 0, 0]);
      const image = ReflectApply(nativeGetImageData, ctx, [0, 0, w, h]); // throws if tainted
      noisePixels(ReflectApply(imageDataData, image, []), w, 0, 0);
      ReflectApply(nativePutImageData, ctx, [image, 0, 0]);
      return copy;
    }

    // Indexed loops throughout: `for...of` would call Array.prototype[Symbol.iterator],
    // which a page may have replaced by the time a child frame is installed.
    const exportMethods = ["toDataURL", "toBlob"];
    if (Canvas && C2D) {
      for (let k = 0; k < exportMethods.length; k++) {
        patchMethod(Canvas, exportMethods[k], function (target, self, args) {
          let copy = null;
          try { copy = noisedCopy(self); } catch (e) { copy = null; }
          // On any failure (tainted canvas, detached, zero size) defer to
          // native on the original so the page sees native errors and results.
          return ReflectApply(target, copy || self, args);
        });
      }
    }

    const glNames = ["WebGLRenderingContext", "WebGL2RenderingContext"];
    for (let k = 0; k < glNames.length; k++) {
      const ctor = win[glNames[k]];
      if (!ctor) continue;
      const bufferHeight = getter(ctor.prototype, "drawingBufferHeight");
      patchMethod(ctor.prototype, "readPixels", function (target, self, args) {
        const result = ReflectApply(target, self, args);
        try {
          const buffer = args[6];
          // RGBA (0x1908) / UNSIGNED_BYTE (0x1401) into a view, no offset form.
          if (args.length === 7 && buffer && isView(buffer) && args[4] === 0x1908 && args[5] === 0x1401) {
            noisePixels(buffer, toNumber(args[2]) | 0, toNumber(args[0]) | 0, toNumber(args[1]) | 0,
                        ReflectApply(bufferHeight, self, []) | 0);
          }
        } catch (e) {}
        return result;
      });
    }

    // Audio readback ---------------------------------------------------------------
    if (win.AudioBuffer) {
      const AB = win.AudioBuffer.prototype;
      const nativeGetChannelData = AB.getChannelData;
      patchMethod(AB, "getChannelData", function (target, self, args) {
        const data = ReflectApply(target, self, args);
        try { noiseSamples(data, toNumber(args[0]) | 0); } catch (e) {}
        return data;
      });
      patchMethod(AB, "copyFromChannel", function (target, self, args) {
        // Noise the live channel (idempotent), then let native copy it.
        try {
          const channel = toNumber(args[1]) | 0;
          noiseSamples(ReflectApply(nativeGetChannelData, self, [channel]), channel);
        } catch (e) {}
        return ReflectApply(target, self, args);
      });
    }

    if (win.AnalyserNode) {
      const AN = win.AnalyserNode.prototype;
      let salt = 0x51;
      const floatReads = ["getFloatFrequencyData", "getFloatTimeDomainData"];
      for (let k = 0; k < floatReads.length; k++) {
        const methodSalt = salt++;
        patchMethod(AN, floatReads[k], function (target, self, args) {
          const result = ReflectApply(target, self, args);
          try { noiseSamples(args[0], methodSalt); } catch (e) {}
          return result;
        });
      }
      const byteReads = ["getByteFrequencyData", "getByteTimeDomainData"];
      for (let k = 0; k < byteReads.length; k++) {
        const methodSalt = salt++;
        patchMethod(AN, byteReads[k], function (target, self, args) {
          const result = ReflectApply(target, self, args);
          try {
            const out = args[0];
            const length = ReflectApply(typedLength, out, []);
            const s = mix(SEED, methodSalt);
            for (let i = 0; i < length; i++) {
              if (out[i] === 0) continue;
              const h = mix(s, i);
              if ((h & 15) === 0) out[i] = (out[i] & 0xfe) | ((h >>> 4) & 1);
            }
          } catch (e) {}
          return result;
        });
      }
    }

    // Child realms -----------------------------------------------------------------
    // Every route to a new same-origin frame's window must patch it *before*
    // returning it. Frames that navigate get the script natively; this covers
    // the ones that never navigate (srcdoc and blob: initial documents) and
    // synchronous access before their navigation completes.
    //
    // These hooks sit on hot DOM paths, so they are plain wrappers over
    // uncurried natives rather than Proxies (which JavaScriptCore will not
    // inline). They still disguise as native: method/accessor shorthand has no
    // `prototype` and cannot be constructed, `name` comes from the key, and
    // `length` is copied from the original.
    const lengthDesc = getOwnPropertyDescriptor(win, "length");
    const frameCount = lengthDesc && lengthDesc.get ? uncurry(lengthDesc.get) : null;

    function installFrames() {
      if (!frameCount) return;
      const count = frameCount(win);
      if (count === 0) return; // the common case: a single getter call
      for (let i = 0; i < count; i++) {
        const child = win[i];
        if (child && !weakSetHas(handledWindows, child)) install(child);
      }
    }

    function adopt(proto, key, part, wrapper, original, desc) {
      defineProperty(wrapper, "length", {
        __proto__: null, value: original.length, writable: false, enumerable: false, configurable: true
      });
      disguise(wrapper, original);
      const replacement = { __proto__: null, enumerable: desc.enumerable, configurable: desc.configurable };
      if (part === "value") { replacement.value = wrapper; replacement.writable = desc.writable; }
      else { replacement.get = desc.get; replacement.set = desc.set; replacement[part] = wrapper; }
      defineProperty(proto, key, replacement);
    }

    // Forward the exact argument count: native "Not enough arguments" errors
    // differ from what an explicit `undefined` argument produces. Dispatching on
    // `arguments.length` alone — never passing `arguments` on — lets
    // JavaScriptCore read the count without materialising an arguments object.
    // Arguments beyond a method's arity are ignored natively, so dropping them
    // is unobservable.
    function hookInsertionMethod(proto, key) {
      const desc = proto && getOwnPropertyDescriptor(proto, key);
      if (!desc || typeof desc.value !== "function") return;
      const native = desc.value, invoke = uncurry(native), arity = native.length;
      const holder = arity === 1
        ? { [key](a) {
              try { return arguments.length === 0 ? invoke(this) : invoke(this, a); }
              finally { installFrames(); } } }
        : arity === 2
        ? { [key](a, b) {
              const n = arguments.length;
              try { return n >= 2 ? invoke(this, a, b) : n === 1 ? invoke(this, a) : invoke(this); }
              finally { installFrames(); } } }
        : { [key](...args) {
              try { return ReflectApply(native, this, args); }
              finally { installFrames(); } } };
      adopt(proto, key, "value", holder[key], native, desc);
    }

    function hookInsertionSetter(proto, key) {
      const desc = proto && getOwnPropertyDescriptor(proto, key);
      if (!desc || typeof desc.set !== "function") return;
      const native = desc.set, invoke = uncurry(native);
      const holder = { set [key](v) {
        try { if (arguments.length === 0) invoke(this); else invoke(this, v); }
        finally { installFrames(); } } };
      adopt(proto, key, "set", getOwnPropertyDescriptor(holder, key).set, native, desc);
    }

    function hookFrameGetter(proto, key, windowOf) {
      const desc = proto && getOwnPropertyDescriptor(proto, key);
      if (!desc || typeof desc.get !== "function") return;
      const native = desc.get, invoke = uncurry(native);
      const holder = { get [key]() {
        const result = invoke(this);
        try { const child = windowOf(result); if (child) install(child); } catch (e) {}
        return result; } };
      adopt(proto, key, "get", getOwnPropertyDescriptor(holder, key).get, native, desc);
    }

    const defaultView = getter(win.Document && win.Document.prototype, "defaultView");
    const frameOwners = ["HTMLIFrameElement", "HTMLFrameElement", "HTMLObjectElement"];
    for (let k = 0; k < frameOwners.length; k++) {
      const proto = win[frameOwners[k]] && win[frameOwners[k]].prototype;
      hookFrameGetter(proto, "contentWindow", function (w) { return w; });
      hookFrameGetter(proto, "contentDocument", function (d) {
        return d && defaultView ? ReflectApply(defaultView, d, []) : null;
      });
    }

    const insertionMethods = [
      ["Node", ["appendChild", "insertBefore", "replaceChild"]],
      ["Element", ["append", "prepend", "before", "after", "replaceWith", "replaceChildren",
                   "insertAdjacentElement", "insertAdjacentHTML", "setHTMLUnsafe"]],
      ["CharacterData", ["before", "after", "replaceWith"]],
      ["DocumentType", ["before", "after", "replaceWith"]],
      ["Document", ["append", "prepend", "replaceChildren", "write", "writeln"]],
      ["ShadowRoot", ["setHTMLUnsafe"]],
      ["Range", ["insertNode", "surroundContents"]]
    ];
    for (let k = 0; k < insertionMethods.length; k++) {
      const ctorName = insertionMethods[k][0], keys = insertionMethods[k][1];
      const proto = win[ctorName] && win[ctorName].prototype;
      for (let j = 0; j < keys.length; j++) hookInsertionMethod(proto, keys[j]);
    }
    const markupOwners = ["Element", "ShadowRoot"];
    for (let k = 0; k < markupOwners.length; k++) {
      const proto = win[markupOwners[k]] && win[markupOwners[k]].prototype;
      hookInsertionSetter(proto, "innerHTML");
      hookInsertionSetter(proto, "outerHTML");
    }
    hookInsertionSetter(win.Document && win.Document.prototype, "body");

    // Parser-inserted frames never pass through a JS method. The parser runs a
    // microtask checkpoint before executing each script, so a MutationObserver
    // patches them before any later inline script can touch them.
    try {
      const observer = new win.MutationObserver(installFrames);
      ReflectApply(win.MutationObserver.prototype.observe, observer,
                   [doc, { __proto__: null, childList: true, subtree: true }]);
    } catch (e) {}

    installFrames();
  }

  install(window);
})();
