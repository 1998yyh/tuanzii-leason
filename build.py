#!/usr/bin/env python3
"""团子课堂 · 构建脚本（标准库零依赖）

1. 扫描 courses/*/course.json → 生成 courses.json
2. 净化拷贝到 dist/（跳过副产物）
坏课跳过并报警，构建不崩。
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
COURSES_DIR = ROOT / "courses"
DIST_DIR = ROOT / "dist"
COURSES_JSON = ROOT / "courses.json"

PORTAL_FILES = ("index.html", "portal.css", "portal.js", "courses.json")
REQUIRED_FIELDS = ("title",)


def warn(msg: str) -> None:
    print(f"⚠️  {msg}", file=sys.stderr)


def load_course(course_dir: Path) -> dict | None:
    """读取并校验一门课；失败返回 None。"""
    slug = course_dir.name
    meta_path = course_dir / "course.json"
    index_path = course_dir / "index.html"

    try:
        raw = meta_path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        warn(f"跳过 {slug}：course.json JSON 语法错误（{e}）")
        return None
    except OSError as e:
        warn(f"跳过 {slug}：无法读取 course.json（{e}）")
        return None

    if not isinstance(data, dict):
        warn(f"跳过 {slug}：course.json 根节点不是对象")
        return None

    for field in REQUIRED_FIELDS:
        if not data.get(field):
            warn(f"跳过 {slug}：course.json 缺 {field} 字段")
            return None

    if not index_path.is_file():
        warn(f"跳过 {slug}：缺少 index.html")
        return None

    modules = data.get("modules") or []
    lessons = data.get("lessons") or []
    if not isinstance(modules, list):
        modules = []
    if not isinstance(lessons, list):
        lessons = []

    return {
        "slug": data.get("slug") or slug,
        "title": data["title"],
        "subtitle": data.get("subtitle") or "",
        "description": data.get("description") or "",
        "moduleCount": len(modules),
        "lessonCount": len(lessons),
        "path": f"courses/{slug}/index.html",
        "status": data.get("status") or "",
    }


def discover_courses() -> list[dict]:
    if not COURSES_DIR.is_dir():
        warn("courses/ 目录不存在，生成空清单")
        return []

    courses: list[dict] = []
    for course_dir in sorted(COURSES_DIR.iterdir()):
        if not course_dir.is_dir():
            continue
        if not (course_dir / "course.json").is_file():
            continue
        entry = load_course(course_dir)
        if entry:
            courses.append(entry)
            print(f"✅ 上架 {entry['slug']}：{entry['title']}（{entry['moduleCount']} 模块 · {entry['lessonCount']} 节课）")

    return courses


def write_courses_json(courses: list[dict]) -> None:
    COURSES_JSON.write_text(
        json.dumps(courses, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"📝 已写入 {COURSES_JSON.relative_to(ROOT)}（{len(courses)} 门课）")


def copy_portal(dist: Path) -> None:
    for name in PORTAL_FILES:
        src = ROOT / name
        if not src.is_file():
            warn(f"门户文件缺失，未拷贝：{name}")
            continue
        shutil.copy2(src, dist / name)


def copy_course_body(slug: str, src_dir: Path, dest_dir: Path) -> None:
    """只拷课程本体：index.html、course.json、lessons/*.html、assets/"""
    dest_dir.mkdir(parents=True, exist_ok=True)

    for name in ("index.html", "course.json"):
        src = src_dir / name
        if src.is_file():
            shutil.copy2(src, dest_dir / name)

    assets_src = src_dir / "assets"
    if assets_src.is_dir():
        shutil.copytree(assets_src, dest_dir / "assets", dirs_exist_ok=True)

    lessons_src = src_dir / "lessons"
    lessons_dest = dest_dir / "lessons"
    if lessons_src.is_dir():
        lessons_dest.mkdir(parents=True, exist_ok=True)
        for html in lessons_src.glob("*.html"):
            shutil.copy2(html, lessons_dest / html.name)


def build_dist(courses: list[dict]) -> None:
    if DIST_DIR.exists():
        shutil.rmtree(DIST_DIR)
    DIST_DIR.mkdir(parents=True)

    copy_portal(DIST_DIR)

    for course in courses:
        slug = course["slug"]
        # 源目录按文件夹名（扫描时的 slug 路径）
        # course["path"] = courses/<folder>/index.html
        folder = course["path"].split("/")[1]
        src = COURSES_DIR / folder
        dest = DIST_DIR / "courses" / folder
        copy_course_body(slug, src, dest)
        print(f"📦 已拷贝 courses/{folder}/ → dist/courses/{folder}/")

    print(f"🚀 dist/ 构建完成 → {DIST_DIR}")


def main() -> int:
    print("=== 团子课堂 build.py ===")
    courses = discover_courses()
    write_courses_json(courses)
    build_dist(courses)
    print(f"=== 完成：上架 {len(courses)} 门课 ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
