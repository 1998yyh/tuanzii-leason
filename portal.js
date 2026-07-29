/**
 * 团子课堂 · 门户渲染
 * fetch courses.json → 辉光课程卡片网格（guardnet 暗黑主题）
 */

function escapeHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderCard(course) {
  const href = course.path || `courses/${course.slug}/index.html`;
  const modules = course.moduleCount ?? 0;
  const lessons = course.lessonCount ?? 0;
  // 副标题和简介拼一段，CSS 里 clamp 4 行
  const blurb = [course.subtitle, course.description].filter(Boolean).join("。");

  return `
    <a class="chapter-card" href="${escapeHtml(href)}" aria-label="进入课程：${escapeHtml(course.title)}">
      <small>${modules} 模块 · ${lessons} 节课</small>
      <h3>${escapeHtml(course.title)}</h3>
      <p>${escapeHtml(blurb)}</p>
      <span class="state">进入课程 →</span>
    </a>
  `;
}

async function loadCourses() {
  const grid = document.getElementById("course-grid");
  try {
    const res = await fetch("courses.json", { cache: "no-cache" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const courses = Array.isArray(data) ? data : data.courses || [];

    if (!courses.length) {
      grid.innerHTML = `<p class="status-msg">暂无上架课程</p>`;
      return;
    }

    grid.innerHTML = courses.map(renderCard).join("");
  } catch (err) {
    console.error("加载 courses.json 失败:", err);
    grid.innerHTML = `<p class="status-msg is-error" role="alert">课程列表加载失败，请确认已运行 python3 build.py</p>`;
  }
}

loadCourses();
