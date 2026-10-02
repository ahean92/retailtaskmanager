"""Срок хранения журнала хода генерации (#37347).

Агент claude cli здесь не запускается: проверяется только судьба файлов журнала — что
удаляется при старте генерации, что остаётся и откуда берётся срок.
"""

import asyncio
import os
import time

import pytest

from app import codegen
from app.config import Settings

DAY = 86400


@pytest.fixture
def log_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(codegen.settings, "codegen_log_dir", str(tmp_path))
    monkeypatch.setattr(codegen.settings, "codegen_log_keep_days", 14)
    return tmp_path


def aged(path, days):
    """Файл, в который последний раз писали days дней назад."""
    path.write_text("гипотеза: старая\n", encoding="utf-8")
    stamp = time.time() - days * DAY
    os.utime(path, (stamp, stamp))
    return path


def test_new_journal_removes_files_older_than_keep_days(log_dir):
    old = aged(log_dir / "20260801-101500.log", 15)
    recent = aged(log_dir / "20260920-101500.log", 13)

    journal = codegen._open_log("Продажи падают после переоценки\nвторая строка")
    journal.close()

    assert not old.exists()
    assert recent.exists()
    created = [p for p in log_dir.iterdir() if p != recent]
    assert len(created) == 1
    assert created[0].read_text(encoding="utf-8").startswith("гипотеза: Продажи падают после переоценки")


def test_keep_days_is_taken_from_the_setting(log_dir, monkeypatch):
    monkeypatch.setattr(codegen.settings, "codegen_log_keep_days", 3)
    five = aged(log_dir / "20260925-080000.log", 5)
    two = aged(log_dir / "20260928-080000.log", 2)

    codegen._open_log("гипотеза").close()

    assert not five.exists()
    assert two.exists()


def test_foreign_files_in_the_same_directory_are_left_alone(log_dir):
    # CODEGEN_LOG_DIR может указывать на общую папку журналов: удаляются только файлы хода
    foreign = [
        aged(log_dir / "uvicorn.log", 100),
        aged(log_dir / "20260101-000000.log.bak", 100),
        aged(log_dir / "notes-20260101-000000.log", 100),
        aged(log_dir / "20260101.log", 100),
    ]

    codegen._open_log("гипотеза").close()

    assert all(p.exists() for p in foreign)


def test_file_that_cannot_be_removed_does_not_break_the_journal(log_dir):
    # папка с именем файла хода: unlink на ней падает, как на файле без прав
    stuck = log_dir / "20260101-000000.log"
    stuck.mkdir()
    stamp = time.time() - 100 * DAY
    os.utime(stuck, (stamp, stamp))
    old = aged(log_dir / "20260102-000000.log", 100)

    journal = codegen._open_log("гипотеза")

    assert journal is not None
    journal.close()
    assert stuck.exists()
    assert not old.exists()


def test_empty_log_dir_means_no_journal_and_no_cleanup(tmp_path, monkeypatch):
    monkeypatch.setattr(codegen.settings, "codegen_log_dir", "")
    monkeypatch.chdir(tmp_path)

    assert codegen._open_log("гипотеза") is None
    assert list(tmp_path.iterdir()) == []


def test_cleanup_happens_at_the_start_of_generation(log_dir, monkeypatch):
    """Через настоящую точку входа: MCP «отвечает», CLI нет — генерация дошла до журнала."""
    old = aged(log_dir / "20260801-120000.log", 30)
    monkeypatch.setattr(codegen, "_probe_mcp", lambda: None)
    monkeypatch.setattr(codegen.settings, "claude_cli", str(log_dir / "no-such-cli"))

    answer = asyncio.run(codegen.generate("гипотеза", "контракт"))

    assert answer["errorCode"] == "noCli"
    assert not old.exists()
    assert len(list(log_dir.glob("*.log"))) == 1


@pytest.mark.parametrize("raw, days", [
    (None, 14),      # не задано — по умолчанию
    ("", 14),
    ("30", 30),
    ("1", 1),
    ("0", 14),       # режима «хранить вечно» нет: ноль и отрицательное — по умолчанию
    ("-7", 14),
    ("две недели", 14),
])
def test_keep_days_setting(monkeypatch, raw, days):
    if raw is None:
        monkeypatch.delenv("CODEGEN_LOG_KEEP_DAYS", raising=False)
    else:
        monkeypatch.setenv("CODEGEN_LOG_KEEP_DAYS", raw)
    assert Settings().codegen_log_keep_days == days
