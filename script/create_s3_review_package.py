#!/usr/bin/env python3
"""Collect sample-only S3 review artifacts; no credentials or network access."""
import argparse
import hashlib
import json
import shutil
import zipfile
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def schema_for(data):
    point = {"type": "object", "additionalProperties": False,
             "required": ["recorded_at", "remaining_percent", "segment"], "properties": {
                 "recorded_at": {"type": "string", "format": "date-time"},
                 "remaining_percent": {"type": "number", "minimum": 0, "maximum": 100},
                 "segment": {"type": "integer", "minimum": 0}}}
    properties = {}
    for key, value in data.items():
        if isinstance(value, bool):
            field = {"type": "boolean"}
        elif isinstance(value, int):
            field = {"type": "integer"}
        elif isinstance(value, float):
            field = {"type": "number"}
        elif isinstance(value, str):
            field = {"type": "string"}
        elif key == "history":
            field = {"type": "array", "items": point}
        else:
            raise ValueError(f"Unexpected template field: {key}")
        if key in {"generated_at", "quota_resets_at"}:
            field["format"] = "date-time"
        if key == "is_sample":
            field["const"] = True
        if key == "schema_version":
            field["const"] = 1
        if key == "minimum_font_pixels":
            field["minimum"] = 18
        if key == "remaining_percent":
            field.update(minimum=0, maximum=100)
        properties[key] = field
    return {"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object",
            "additionalProperties": False, "required": list(data), "properties": properties,
            "description": "Codex 脉动 S3 0.1.0 示例数据契约提案；需平台安装渲染映射后使用。"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="CODEX_PULSE_S3_RENDER_DIR output")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--app-id", required=True, help="Non-secret sandbox application ID")
    args = parser.parse_args()
    project = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    templates = []
    for screen in ("A", "B"):
        source = args.input / "review-sample"
        request_path = source / f"screen-{screen}-request-proposal.json"
        request = json.loads(request_path.read_text())
        assert request["data"]["is_sample"] is True
        assert set(request) == {"template", "screen", "data", "expires_in_seconds"}
        assert "image_url" not in request["data"]
        for suffix in ("sample.png", "sample.svg", "layout.json", "request-proposal.json"):
            target = output / "samples" / f"screen-{screen}-{suffix}"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / target.name, target)
        proposal = {"template_id": request["template"], "name": f"Codex 脉动 · {screen} 屏示例",
                    "category": "office", "enabled": True,
                    "schema_definition": schema_for(request["data"])}
        dump(output / "templates" / f"{request['template']}-proposal.json", proposal)
        templates.append({"id": request["template"], "screen": screen, "status": "proposed_not_installed"})
    for path in args.input.glob("screen-*.png"):
        folder = output / "size-previews"
        folder.mkdir(exist_ok=True)
        shutil.copyfile(path, folder / path.name)
    shutil.copyfile(args.input / "review-sample/s3-settings.png", output / "local-settings-reference.png")
    shutil.copyfile(project / "docs/S3_XIAOWU_CREATOR.md", output / "接入说明.md")
    dump(output / "template-inventory.json", {"application_id": args.app_id, "version": "0.1.0",
         "stage": "local_candidate_platform_configuration_pending", "templates": templates,
         "online_sandbox_verified": False, "physical_device_verified": False})
    notes = ("Codex 脉动 S3 双屏 0.1.0 本地候选版：A 屏额度与用量，B 屏重置预告与七日趋势；"
             "至少 18px 字号、黑白降级、独立节流、示例数据 OpenAPI 推送。"
             "已准备本地设计和测试资料；测试设备、模板渲染映射及像素规格待平台提供，线上沙箱与实机尚未验证。"
             "本稿供预审与模板对接，完成正式联调后更新验证记录再提交。")
    assert len(notes) <= 1000
    dump(output / "review-submission-draft.json", {"version": "0.1.0", "notes": notes})
    files = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(output.rglob("*")) if p.is_file() and p.name != "manifest.json"}
    dump(output / "manifest.json", {"generated_at_beijing": datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(),
         "application_id": args.app_id, "contains_credentials": False, "contains_real_account_data": False,
         "online_sandbox_verified": False, "physical_device_verified": False, "files_sha256": files})
    archive = output.parent / "Codex-Pulse-S3-Review-0.1.0.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(output.rglob("*")):
            if path.is_file():
                z.write(path, "Codex-Pulse-S3-Review-0.1.0/" + str(path.relative_to(output)))
    print(f"Review folder: {output}")
    print(f"Review ZIP: {archive}")
    print("Stage: local candidate; platform configuration, online sandbox, and device verification pending.")


if __name__ == "__main__":
    main()
