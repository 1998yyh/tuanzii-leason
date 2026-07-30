/**
 * 团子课堂 · 课时页增强
 * 1. 把 pre.code 包成带工具栏的代码卡片（语言标签 + 一键复制）
 * 2. 把正文表格包一层 .table-scroll 滚动容器（小屏横滚不破版）
 * 无 JS 时 pre.code 自带卡片样式、表格小屏压列兜底，不碍事
 */
(function () {
  "use strict";

  function langOf(pre) {
    var code = pre.querySelector("code");
    var m = code && code.className.match(/lang-([\w+-]+)/);
    return m ? m[1] : "code";
  }

  function enhance(pre) {
    // 这个SB函数把裸 pre 包成代码卡片，别tm重复包
    if (pre.closest("figure.code-card")) return;

    var figure = document.createElement("figure");
    figure.className = "code-card";

    var bar = document.createElement("div");
    bar.className = "code-toolbar";

    var label = document.createElement("span");
    label.textContent = langOf(pre);

    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "copy-code";
    btn.textContent = "复制";
    btn.addEventListener("click", function () {
      var text = pre.innerText;
      function done() {
        btn.textContent = "已复制 ✓";
        setTimeout(function () { btn.textContent = "复制"; }, 1600);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(); });
      } else {
        fallback();
      }
      function fallback() {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.style.position = "fixed";
        ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); done(); } catch (e) { btn.textContent = "复制失败"; }
        document.body.removeChild(ta);
      }
    });

    bar.appendChild(label);
    bar.appendChild(btn);
    pre.parentNode.insertBefore(figure, pre);
    figure.appendChild(bar);
    figure.appendChild(pre);
  }

  document.querySelectorAll("pre.code").forEach(enhance);

  // 这个SB函数把裸 table 包成可横滚的容器，小屏不再把页面顶穿，别tm重复包
  function wrapTable(table) {
    if (table.parentNode.classList && table.parentNode.classList.contains("table-scroll")) return;
    var wrap = document.createElement("div");
    wrap.className = "table-scroll";
    table.parentNode.insertBefore(wrap, table);
    wrap.appendChild(table);
  }

  document.querySelectorAll("main.chapter table").forEach(wrapTable);
})();
