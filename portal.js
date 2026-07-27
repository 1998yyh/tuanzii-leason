/**
 * 团子课堂 · 门户渲染
 * fetch courses.json → 卡片网格；封面 = 标题首字 + slug 哈希 pastel 渐变
 */

function hashSlug(slug) {
  let h = 0;
  for (let i = 0; i < slug.length; i++) {
    h = (h * 31 + slug.charCodeAt(i)) >>> 0;
  }
  return h;
}

/**
 * 由 slug 生成稳定的 pastel 双色调封面：
 * 同色相浅渐变做底，深色 glyph 压在上面，跟暖白纸感底和谐
 */
function coverStyle(slug) {
  const h = hashSlug(slug) % 360;
  const h2 = (h + 24) % 360;
  const bg = `linear-gradient(135deg, hsl(${h} 68% 91%), hsl(${h2} 58% 83%))`;
  const fg = `hsl(${h} 45% 32%)`;
  return `background:${bg};color:${fg}`;
}

function coverGlyph(title) {
  const t = (title || "").trim();
  return t ? t[0] : "课";
}

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
  const cover = coverStyle(course.slug);
  const glyph = coverGlyph(course.title);

  return `
    <a class="course-card" href="${escapeHtml(href)}" aria-label="进入课程：${escapeHtml(course.title)}">
      <div class="card-cover" style="${cover}" aria-hidden="true">${escapeHtml(glyph)}</div>
      <div class="card-body">
        <h2 class="card-title">${escapeHtml(course.title)}</h2>
        <p class="card-subtitle">${escapeHtml(course.subtitle || "")}</p>
        <p class="card-desc">${escapeHtml(course.description || "")}</p>
        <p class="card-meta">${modules} 模块 · ${lessons} 节课</p>
      </div>
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
