/*
 * The page half of autofill, the same source in both engines.
 *
 * It is one expression: a function that takes `report` -- the engine's way
 * back to its host -- and returns `fill`, which only the host can call.
 *
 *   Chromium  palm-browser-cef runs it in the top-level frame's main world
 *             from OnContextCreated, before any page script exists; `report`
 *             is a native V8 function and `wake` the name of an event (128
 *             random bits) that makes `fill` pull the parked values from
 *             report('pull'). Nothing is put on a global, so page script
 *             cannot call or replace either.
 *   Firefox   the Gecko host installs it as a BiDi preload script in a
 *             sandbox ("palm-autofill"): a separate realm that sees the DOM
 *             through Xray wrappers. `report` is a BiDi channel; `fill` lives
 *             on the sandbox's global and is reached with script.callFunction
 *             in the same sandbox, its arguments serialized by the protocol.
 *
 * What it promises:
 *
 *   - It reports focus only for login fields of the top-level document
 *     (username, current password, one-time code), with the field's rectangle
 *     and location.origin. The host compares that origin with the one it
 *     knows and drops the report when they differ.
 *   - It never puts a value in a field on its own. Until the host calls
 *     `fill`, after the person picked a login in the chrome, the page reads
 *     empty fields.
 *   - `fill` refuses unless location.origin is still the origin the person
 *     filled for, and refuses a form whose action posts to another origin.
 *     The password goes into the field through the native value setter of
 *     HTMLInputElement, captured before page script ran, and into nothing
 *     else: no page-overridable function is ever handed it. Then `input` and
 *     `change` are dispatched, which is what React and friends listen for;
 *     the native setter also bypasses React's own value tracker, so React
 *     sees the change as a change.
 *   - On a trusted submit of a form carrying a password it reports the
 *     username, the (new) password and, for a change-password form, the old
 *     one, so the chrome can offer to save or update the login.
 *
 * Everything it uses is captured at start, before the page can redefine
 * prototypes (which matters in Chromium's main world; Firefox's sandbox would
 * not see redefinitions anyway).
 */
(function (report, wake) {
  'use strict';
  const W = window, D = document;
  if (W.top !== W) return null;
  const apply = Reflect.apply;
  const gopd = Object.getOwnPropertyDescriptor;
  const desc = (o, n) => gopd(o, n) || {};
  const IP = HTMLInputElement.prototype, EP = Element.prototype, NP = Node.prototype;
  const valueGet = desc(IP, 'value').get, valueSet = desc(IP, 'value').set;
  const typeGet = desc(IP, 'type').get, formGet = desc(IP, 'form').get;
  const disabledGet = desc(IP, 'disabled').get, readOnlyGet = desc(IP, 'readOnly').get;
  const getAttr = EP.getAttribute, rectOf = EP.getBoundingClientRect;
  const docQsa = Document.prototype.querySelectorAll, elQsa = EP.querySelectorAll;
  const activeGet = desc(Document.prototype, 'activeElement').get;
  const connectedGet = desc(NP, 'isConnected').get;
  const position = NP.compareDocumentPosition;
  const dispatch = EventTarget.prototype.dispatchEvent;
  const listen = EventTarget.prototype.addEventListener;
  const actionGet = desc(HTMLFormElement.prototype, 'action').get;
  // isTrusted is [LegacyUnforgeable]: an own, non-configurable property of
  // every event, which page script can neither redefine nor fake
  const targetGet = desc(Event.prototype, 'target').get;
  const keyGet = desc(KeyboardEvent.prototype, 'key').get;
  const Ev = Event, IEv = InputEvent, URLc = URL;
  const raf = W.requestAnimationFrame.bind(W);
  const origin = () => W.location.origin;

  const isInput = (el) => {
    if (!el) return false;
    try { apply(typeGet, el, []); return true; } catch (e) { return false; }
  };
  const typeOf = (el) => apply(typeGet, el, []);
  const attr = (el, n) => String(apply(getAttr, el, [n]) || '').toLowerCase();
  const tokens = (el) => ' ' + attr(el, 'autocomplete').split(/\s+/).join(' ') + ' ';
  const textish = (t) => t === 'text' || t === 'email' || t === 'tel';
  const usable = (el) => !apply(disabledGet, el, []) && !apply(readOnlyGet, el, []);
  const visible = (el) => {
    const r = apply(rectOf, el, []);
    return r.width > 0 && r.height > 0;
  };
  const inputs = (root) => {
    const list = root === D ? apply(docQsa, D, ['input']) : apply(elQsa, root, ['input']);
    const out = [];
    for (let i = 0; i < list.length; i++) out.push(list[i]);
    return out;
  };
  const passwords = (root) => inputs(root).filter((el) => typeOf(el) === 'password' && usable(el) && visible(el));
  const follows = (a, b) => (apply(position, a, [b]) & 4) !== 0; // b comes after a
  const formOf = (el) => apply(formGet, el, []);

  const kindOf = (el) => {
    if (!isInput(el) || !usable(el)) return 0;
    const t = typeOf(el), ac = tokens(el);
    if (ac.includes(' one-time-code ')) return 3;
    if (t === 'password') return ac.includes(' new-password ') ? 0 : 2;
    if (!textish(t)) return 0;
    if (ac.includes(' username ')) return 1;
    const root = formOf(el) || D;
    if (passwords(root).some((pw) => follows(el, pw))) return 1;
    // a username-first login (the password is on the next step)
    const hint = attr(el, 'name') + ' ' + attr(el, 'id') + ' ' + attr(el, 'placeholder') + ' ' + attr(el, 'aria-label');
    if (/user|login|e-?mail|account|identifier|sign.?in/.test(hint) && formOf(el) &&
        inputs(root).filter((x) => textish(typeOf(x)) && visible(x)).length <= 2) return 1;
    return 0;
  };

  // the username field that goes with a password field: an autocomplete
  // username, else the nearest visible text field before it. A submit also
  // reads a hidden username field (what a change-password form carries so
  // password managers know whose password changed); a fill never writes one.
  const usernameFor = (pw, root, submitting) => {
    const all = inputs(root);
    for (const el of all) if (tokens(el).includes(' username ') && usable(el) && visible(el)) return el;
    if (submitting) for (const el of all) if (tokens(el).includes(' username ') && apply(valueGet, el, []) !== '') return el;
    let best = null;
    for (const el of all) {
      if (el === pw) break;
      if (textish(typeOf(el)) && usable(el) && visible(el) && !tokens(el).includes(' one-time-code ')) best = el;
    }
    return best;
  };

  let last = null, shown = false, pending = false;
  const send = (el) => {
    const k = kindOf(el);
    if (!k) {
      if (shown) {
        shown = false;
        report('focus', 0, 0, 0, 0, 0, origin());
      }
      return;
    }
    last = el;
    shown = true;
    const r = apply(rectOf, el, []);
    report('focus', k, r.left, r.top, r.width, r.height, origin());
  };
  const again = () => {
    pending = false;
    const a = apply(activeGet, D, []);
    if (shown && a === last) send(a);
  };
  const soon = () => {
    if (shown && !pending) { pending = true; raf(again); }
  };
  // On window, in the capture phase, registered before any page script: the
  // first listener on the event path, so a page cannot stop it reaching us.
  apply(listen, W, ['focusin', (e) => send(apply(targetGet, e, [])), true]);
  apply(listen, W, ['scroll', soon, true]);
  apply(listen, W, ['resize', soon, true]);

  const collect = (root) => {
    const pws = inputs(root).filter((el) => typeOf(el) === 'password' && apply(valueGet, el, []) !== '');
    if (!pws.length) return;
    const val = (el) => apply(valueGet, el, []);
    const fresh = pws.filter((el) => tokens(el).includes(' new-password '));
    const current = pws.filter((el) => tokens(el).includes(' current-password '));
    let pw = '', old = '';
    if (fresh.length) {
      pw = val(fresh[0]);
      old = current.length ? val(current[0]) : (pws[0] !== fresh[0] ? val(pws[0]) : '');
    } else if (pws.length >= 3) {
      old = val(pws[0]); pw = val(pws[1]);
    } else if (pws.length === 2 && val(pws[0]) !== val(pws[1])) {
      old = val(pws[0]); pw = val(pws[1]);
    } else {
      pw = val(pws[0]);
    }
    const u = usernameFor(pws[0], root, true);
    report('submit', origin(), u ? val(u) : '', pw, old);
  };
  apply(listen, W, ['submit', (e) => {
    if (e.isTrusted !== true) return;
    const f = apply(targetGet, e, []);
    collect(f);
  }, true]);
  // a login with no <form>: Enter in its password field
  apply(listen, W, ['keydown', (e) => {
    if (e.isTrusted !== true || apply(keyGet, e, []) !== 'Enter') return;
    const t = apply(targetGet, e, []);
    if (isInput(t) && typeOf(t) === 'password' && !formOf(t)) collect(D);
  }, true]);

  // a field focused before this script was installed (an autofocus, where
  // the engine installs it late) is reported now
  send(apply(activeGet, D, []));
  // ... and so is one a page focused while the view itself had no focus,
  // which moves activeElement without a focusin
  const settle = () => {
    const a = apply(activeGet, D, []);
    if (a !== last || !shown) send(a);
  };
  apply(listen, D, ['DOMContentLoaded', settle, true]);
  apply(listen, W, ['load', settle, true]);
  apply(listen, W, ['focus', settle, true]);

  const put = (el, v) => {
    apply(valueSet, el, [v]);
    apply(dispatch, el, [new IEv('input', { bubbles: true, composed: true, inputType: 'insertReplacementText' })]);
    apply(dispatch, el, [new Ev('change', { bubbles: true })]);
  };

  // Chromium wakes the filler with an event whose name only it and this
  // closure know; the values come from report('pull'), never from the event.
  if (typeof wake === 'string' && wake) {
    apply(listen, W, [wake, () => {
      const a = report('pull');
      if (a) report('result', fill(a[0], a[1], a[2], a[3]));
    }, true]);
  }

  // fill returns PB_FILL_*: 0 filled, 1 origin changed, 2 no field, 3 the
  // form posts elsewhere.
  function fill(want, username, password, otp) {
    if (origin() !== want) return 1;
    let el = apply(activeGet, D, []);
    if (!kindOf(el)) el = last && apply(connectedGet, last, []) && kindOf(last) ? last : null;
    if (!el) el = passwords(D).filter((x) => !tokens(x).includes(' new-password '))[0] || null;
    if (!el) return 2;
    const k = kindOf(el);
    if (k === 3) {
      if (!otp) return 2;
      put(el, otp);
      return 0;
    }
    const form = formOf(el);
    if (form) {
      let to = '';
      try { to = new URLc(apply(actionGet, form, [])).origin; } catch (e) { to = ''; }
      if (to !== origin()) return 3;
    }
    const root = form || D;
    let pw = k === 2 ? el : null;
    let us = k === 1 ? el : null;
    if (!pw) {
      const all = passwords(root).filter((x) => !tokens(x).includes(' new-password '));
      pw = all.find((x) => !us || follows(us, x)) || null;
    }
    if (!us && pw) us = usernameFor(pw, root);
    if (us && typeOf(us) === 'password') us = null;
    if (!us && !pw) return 2;
    if (us && username) put(us, username);
    if (pw && password && typeOf(pw) === 'password') put(pw, password);
    return 0;
  }
  return fill;
})
