import { useCallback, useEffect, useRef, useState } from "react";
import { PlayIcon } from "lucide-react";
import { cn } from "~/lib/utils";

/**
 * The film, on the homepage.
 *
 * Three things this has to get right, in order of how annoyed people get when
 * it does not:
 *
 *  1. **Never autoplay with sound.** Every browser blocks it, and the ones
 *     that do not should. What plays on its own is a muted, looping preview of
 *     the cold open; the full film, with the score, starts on a click and from
 *     the beginning.
 *  2. **Respect `prefers-reduced-motion`.** Those viewers get the poster and a
 *     play control, and nothing moves until they ask it to.
 *  3. **Do not move the page.** The frame reserves its 16:9 box before any
 *     media exists, and the poster sits inside it, so the layout is identical
 *     before and after the video element mounts.
 *
 * It is also lazy: the `<video>` is not in the DOM at all until the section is
 * near the viewport, so a visitor who never scrolls this far pays nothing for
 * it beyond a poster frame.
 */

const WEBM = "/film/palmy.webm";
const MP4 = "/film/palmy.mp4";
const POSTER = "/film/palmy-poster.jpg";
const VTT = "/film/film.vtt";

/**
 * How much of the film the silent preview loops. 13.3 s is exactly the first
 * eight bars of the score: the window manager with four applications in it,
 * the title, and the card that says how old the project is. The loop ends on
 * a bar line, so a viewer who leaves it running never hears it restart
 * mid-phrase.
 */
const PREVIEW_END = 13.3;
const DURATION = "2:13";

export function Film({ className }: { className?: string }) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const videoRef = useRef<HTMLVideoElement | null>(null);

  // `mounted` gates everything that depends on the browser, so the prerendered
  // HTML and the first client render agree: both are the poster.
  const [near, setNear] = useState(false);
  const [reduced, setReduced] = useState(true);
  const [playing, setPlaying] = useState(false);

  useEffect(() => {
    const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
    const sync = () => setReduced(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;
    if (typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setNear(true);
          io.disconnect();
        }
      },
      { rootMargin: "300px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  /** Loop the preview by hand, so the same file serves both roles. */
  const onTimeUpdate = useCallback(() => {
    const v = videoRef.current;
    if (!v || playing) return;
    if (v.currentTime >= PREVIEW_END) v.currentTime = 0;
  }, [playing]);

  // Starting has to be two steps, not one. For a reduced-motion viewer the
  // <video> does not exist until `playing` is set, so there is nothing to
  // call play() on inside the click handler; the effect runs after the
  // element commits, while the click's user activation is still live, which
  // is what lets it start unmuted.
  const start = useCallback(() => setPlaying(true), []);

  useEffect(() => {
    if (!playing) return;
    const v = videoRef.current;
    if (!v) return;
    v.muted = false;
    v.loop = false;
    v.currentTime = 0;
    void v.play();
  }, [playing]);

  const showVideo = near && (!reduced || playing);

  return (
    <div className={cn("min-w-0", className)}>
      <div
        ref={hostRef}
        className="relative aspect-video w-full overflow-hidden rounded-xl border bg-black"
      >
        {/* The poster is always under the video, so there is never a flash of
            empty box while the first frames arrive. */}
        <img
          src={POSTER}
          alt="Four applications running inside the palmy window manager"
          loading="lazy"
          decoding="async"
          className="absolute inset-0 size-full object-cover"
        />

        {showVideo && (
          <video
            ref={videoRef}
            className="absolute inset-0 size-full object-cover"
            poster={POSTER}
            preload="metadata"
            muted={!playing}
            loop={!playing}
            autoPlay={!reduced && !playing}
            playsInline
            controls={playing}
            onTimeUpdate={onTimeUpdate}
            onEnded={() => setPlaying(false)}
          >
            <source src={WEBM} type="video/webm" />
            <source src={MP4} type="video/mp4" />
            <track
              kind="captions"
              srcLang="en"
              label="English"
              src={VTT}
              default
            />
          </video>
        )}

        {!playing && (
          <button
            type="button"
            onClick={start}
            aria-label={`Play the film with sound, ${DURATION}`}
            className="group absolute inset-0 flex flex-col items-center justify-center gap-3 bg-black/35 transition hover:bg-black/45"
          >
            {/* Centred, so it stays clear of the caption line along the
                bottom of the frame while the silent preview runs. */}
            <span className="flex size-12 items-center justify-center rounded-full bg-white/95 text-black shadow-lg transition group-hover:scale-105 sm:size-14">
              <PlayIcon className="size-5 translate-x-px fill-current sm:size-6" />
            </span>
            <span className="px-4 text-center text-xs font-medium text-white drop-shadow sm:text-sm">
              Play with sound
              <span className="font-normal text-white/70">
                {" \u00b7 "}
                {DURATION}
                {" \u00b7 original score \u00b7 captions"}
              </span>
            </span>
          </button>
        )}
      </div>
    </div>
  );
}
