// Keeps the caption under the hero video in step with the recording.
// Step start times are the data-at values (seconds) in home.html.
const video = document.querySelector(".demo-video");
const caption = document.querySelector("[data-demo-caption]");
const steps = [...document.querySelectorAll("[data-demo-steps] li")].map((item) => ({
  at: Number(item.dataset.at),
  text: item.textContent,
}));

if (video && caption && steps.length) {
  let shown = -1;

  const update = () => {
    let index = 0;
    for (let i = 0; i < steps.length; i += 1) {
      if (video.currentTime >= steps[i].at) index = i;
    }
    if (index === shown) return;
    shown = index;
    caption.textContent = steps[index].text;
  };

  const follow = () => {
    update();
    if (!video.paused && !video.ended) requestAnimationFrame(follow);
  };

  // The video has no browser controls, so a click pauses and resumes it.
  video.addEventListener("click", () => {
    if (video.paused) video.play();
    else video.pause();
  });

  video.addEventListener("play", follow);
  video.addEventListener("timeupdate", update);
  video.addEventListener("seeked", update);
  follow();
}
