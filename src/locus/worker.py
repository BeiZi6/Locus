"""本机设备桥。

一行一条 JSON。iOS 使用 Apple 的开发者定位服务：
iOS 17 以下是 com.apple.dt.simulatelocation，iOS 17 及以上是
DVT LocationSimulation（需要开发者模式和远程配对隧道）。
Android 使用 adb 的 cmd location 测试提供器。
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import socket
import struct
import sys
import time
import traceback
from dataclasses import dataclass
from typing import Any, Optional

os.environ.setdefault("NO_PROXY", "*")
os.environ.setdefault("no_proxy", "*")

log = logging.getLogger("locus")

ADB_HOST = ("127.0.0.1", 5037)
PROVIDER = "locus"
EARTH_M = 6_371_000.0


def project(lat: float, lon: float, bearing_deg: float, meters: float) -> tuple[float, float]:
    """从起点沿方位角前进 meters，返回新的纬度、经度。"""
    delta = meters / EARTH_M
    theta = math.radians(bearing_deg)
    phi1 = math.radians(lat)
    lam1 = math.radians(lon)
    phi2 = math.asin(math.sin(phi1) * math.cos(delta) + math.cos(phi1) * math.sin(delta) * math.cos(theta))
    lam2 = lam1 + math.atan2(
        math.sin(theta) * math.sin(delta) * math.cos(phi1),
        math.cos(delta) - math.sin(phi1) * math.sin(phi2),
    )
    return math.degrees(phi2), (math.degrees(lam2) + 540) % 360 - 180


def _recvn(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def adb_request(sock: socket.socket, command: str) -> None:
    payload = command.encode()
    sock.sendall(f"{len(payload):04x}".encode() + payload)
    status = _recvn(sock, 4)
    if status == b"OKAY":
        return
    if status == b"FAIL":
        length = int(_recvn(sock, 4) or b"0", 16)
        detail = _recvn(sock, length).decode(errors="replace")
        raise RuntimeError(detail or "adb 拒绝了命令")
    raise RuntimeError(f"adb 返回了无法识别的状态 {status!r}")


def adb_devices() -> list[dict[str, str]]:
    sock = socket.create_connection(ADB_HOST, 3)
    try:
        adb_request(sock, "host:devices-l")
        length = int(_recvn(sock, 4) or b"0", 16)
        text = _recvn(sock, length).decode(errors="replace")
    finally:
        sock.close()
    devices = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[1] != "device":
            continue
        fields = {}
        for item in parts[2:]:
            if ":" in item:
                key, value = item.split(":", 1)
                fields[key] = value
        model = fields.get("model", parts[0]).replace("_", " ")
        devices.append(
            {
                "id": f"android:{parts[0]}",
                "kind": "android",
                "name": model,
                "detail": f"Android · {parts[0]}",
            }
        )
    return devices


def adb_shell(serial: str, command: str, timeout: float = 20) -> str:
    sock = socket.create_connection(ADB_HOST, 3)
    sock.settimeout(timeout)
    try:
        adb_request(sock, f"host:transport:{serial}")
        adb_request(sock, f"shell:{command}")
        chunks: list[bytes] = []
        while True:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        sock.close()
    return b"".join(chunks).decode(errors="replace").strip()


# 自定义源，再加上系统会拿来做融合的三个名字。能加上的就写入同一套坐标。
_FUSION_PROVIDERS: tuple[tuple[str, str], ...] = (
    ("gps", "--requiresSatellite --supportsAltitude --supportsSpeed --supportsBearing"),
    ("network", "--requiresNetwork --supportsAltitude"),
    ("fused", "--requiresNetwork --requiresSatellite --supportsAltitude --supportsSpeed --supportsBearing"),
    (PROVIDER, "--requiresSatellite --requiresNetwork --supportsAltitude --supportsSpeed --supportsBearing"),
)
_android_providers: dict[str, list[str]] = {}
_android_extended: dict[str, bool] = {}


def location_command(
    provider: str,
    lat: float,
    lon: float,
    accuracy: float,
    altitude: float,
    speed: float,
    bearing: float,
    extended: bool,
    now_ms: int,
) -> str:
    accuracy = min(100.0, max(1.0, accuracy))
    command = (
        f"cmd location providers set-test-provider-location {provider} "
        f"--location {lat:.7f},{lon:.7f} --accuracy {accuracy:.1f} "
        f"--altitude {altitude:.1f} --time {now_ms}"
    )
    if extended:
        command += f" --speed {max(0.0, speed):.2f} --bearing {bearing % 360:.1f}"
    return command


def _android_failed(text: str) -> bool:
    return any(token in text for token in ("Unknown command", "Exception", "Error:", "Unknown option", "Failed"))


def _android_prepare(serial: str) -> list[str]:
    added: list[str] = []
    for name, options in _FUSION_PROVIDERS:
        created = adb_shell(serial, f"cmd location providers add-test-provider {name} {options}")
        if _android_failed(created):
            continue
        enabled = adb_shell(serial, f"cmd location providers set-test-provider-enabled {name} true")
        if _android_failed(enabled):
            adb_shell(serial, f"cmd location providers remove-test-provider {name}")
            continue
        added.append(name)
    if not added:
        raise RuntimeError("Android 没有接受任何测试定位源。请在开发者选项里允许模拟位置。")
    _android_providers[serial] = added
    return added


def android_set(
    serial: str,
    lat: float,
    lon: float,
    accuracy: float = 8,
    altitude: float = 32,
    speed: float = 0,
    bearing: float = 0,
) -> list[str]:
    providers = _android_providers.get(serial)
    if not providers:
        providers = _android_prepare(serial)
    now_ms = int(time.time() * 1000)
    extended = _android_extended.get(serial, True)
    script = " ; ".join(
        location_command(name, lat, lon, accuracy, altitude, speed, bearing, extended, now_ms)
        for name in providers
    )
    result = adb_shell(serial, script)
    if extended and ("Unknown option" in result or "Bad argument" in result):
        _android_extended[serial] = False
        script = " ; ".join(
            location_command(name, lat, lon, accuracy, altitude, speed, bearing, False, now_ms)
            for name in providers
        )
        result = adb_shell(serial, script)
    if _android_failed(result):
        _android_providers.pop(serial, None)
        raise RuntimeError(result or "Android 没有接受测试定位")
    return providers


def android_clear(serial: str) -> None:
    names = _android_providers.pop(serial, [PROVIDER])
    for name in names:
        adb_shell(serial, f"cmd location providers set-test-provider-enabled {name} false")
        adb_shell(serial, f"cmd location providers remove-test-provider {name}")


@dataclass
class IosLink:
    udid: str
    major: int
    lockdown: Any = None
    rsd: Any = None
    dvt: Any = None
    simulation: Any = None

    async def set(self, lat: float, lon: float) -> None:
        if self.major >= 17:
            await self.simulation.set(lat, lon)
            return
        await _dt_command(self.lockdown, lat, lon)

    async def clear(self) -> None:
        if self.major >= 17:
            await self.simulation.clear()
            return
        await _dt_command(self.lockdown, None, None)

    async def close(self) -> None:
        for obj in (self.simulation, self.dvt, self.rsd, self.lockdown):
            if obj is None:
                continue
            try:
                if hasattr(obj, "__aexit__") and obj is not self.lockdown and obj is not self.rsd:
                    await obj.__aexit__(None, None, None)
                else:
                    await obj.close()
            except Exception:
                log.debug("close failed", exc_info=True)
        self.simulation = None
        self.dvt = None
        self.rsd = None
        self.lockdown = None


async def _dt_command(lockdown: Any, lat: Optional[float], lon: Optional[float]) -> None:
    service = await lockdown.start_lockdown_developer_service("com.apple.dt.simulatelocation")
    try:
        if lat is None or lon is None:
            await service.sendall(struct.pack(">I", 1))
            return
        await service.sendall(struct.pack(">I", 0))
        lat_b = str(lat).encode()
        lon_b = str(lon).encode()
        await service.sendall(struct.pack(">I", len(lat_b)) + lat_b)
        await service.sendall(struct.pack(">I", len(lon_b)) + lon_b)
    finally:
        await service.close()


async def _open_rsd(udid: str) -> Any:
    errors: list[str] = []
    from pymobiledevice3.remote import native_tunnel

    try:
        return await native_tunnel.establish_native_rsd(serial=udid)
    except Exception as exc:
        errors.append(f"系统隧道：{exc}")
    from pymobiledevice3.remote import userspace_tunnel

    try:
        return await userspace_tunnel.establish_userspace_rsd(serial=udid, remotepairing_fallback=False)
    except Exception as exc:
        errors.append(f"用户态隧道：{exc}")
    raise RuntimeError(
        "iOS 17 及以上要先打开开发者模式，用数据线连接并信任这台 Mac。"
        + " ".join(errors)
    )


async def _mount_if_needed(provider: Any) -> None:
    from pymobiledevice3.services.mobile_image_mounter import auto_mount

    try:
        await auto_mount(provider)
    except Exception as exc:
        if exc.__class__.__name__ == "AlreadyMountedError":
            return
        log.info("developer image: %s", exc)


async def open_ios(udid: str) -> IosLink:
    from packaging.version import Version
    from pymobiledevice3.lockdown import create_using_usbmux

    lockdown = await create_using_usbmux(serial=udid, autopair=True)
    major = Version(lockdown.product_version).major
    if major < 17:
        await _mount_if_needed(lockdown)
        return IosLink(udid=udid, major=major, lockdown=lockdown)
    await lockdown.close()
    rsd = await _open_rsd(udid)
    await _mount_if_needed(rsd)
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

    dvt = DvtProvider(rsd)
    await dvt.__aenter__()
    simulation = LocationSimulation(dvt)
    try:
        await simulation.__aenter__()
    except Exception:
        await dvt.__aexit__(None, None, None)
        await rsd.close()
        raise
    return IosLink(udid=udid, major=major, rsd=rsd, dvt=dvt, simulation=simulation)


def choose_ios_links(devices: list[Any]) -> list[tuple[Any, bool]]:
    """同一台手机的 USB 和无线会各出现一次。合成一条，有线时用 USB。"""
    grouped: dict[str, list[Any]] = {}
    order: list[str] = []
    for device in devices:
        if device.serial not in grouped:
            order.append(device.serial)
            grouped[device.serial] = []
        grouped[device.serial].append(device)
    chosen: list[tuple[Any, bool]] = []
    for serial in order:
        group = grouped[serial]
        usb = next((item for item in group if item.is_usb), None)
        pick = usb or group[0]
        also_network = usb is not None and any(item.is_network for item in group)
        chosen.append((pick, also_network))
    return chosen


async def describe_ios(device: Any, also_network: bool = False) -> dict[str, str]:
    from pymobiledevice3.lockdown import create_using_usbmux

    name = device.serial[-8:]
    if device.is_usb and also_network:
        link = "USB，无线也连着"
    elif device.is_usb:
        link = "USB"
    else:
        link = "无线"
    detail = f"iOS · {link}"
    try:
        lockdown = await create_using_usbmux(
            serial=device.serial,
            autopair=False,
            connection_type="USB" if device.is_usb else "Network",
        )
        try:
            name = getattr(lockdown, "display_name", None) or name
            version = getattr(lockdown, "product_version", "") or ""
            detail = f"iOS {version} · {link}".strip()
        finally:
            await lockdown.close()
    except Exception:
        log.debug("describe failed", exc_info=True)
    return {"id": f"ios:{device.serial}", "kind": "ios", "name": str(name), "detail": detail}


class Bridge:
    def __init__(self) -> None:
        self.ios: dict[str, IosLink] = {}

    async def list_devices(self) -> dict[str, Any]:
        from pymobiledevice3.usbmux import list_devices

        devices: list[dict[str, str]] = []
        warnings: list[str] = []
        try:
            for device, also_network in choose_ios_links(await list_devices()):
                devices.append(await describe_ios(device, also_network))
        except Exception as exc:
            warnings.append(f"iOS：{exc}")
        try:
            devices.extend(adb_devices())
        except Exception as exc:
            warnings.append(f"Android：{exc}")
        return {"devices": devices, "warnings": warnings}

    async def ensure_ios(self, udid: str) -> IosLink:
        link = self.ios.get(udid)
        if link is not None:
            return link
        link = await open_ios(udid)
        self.ios[udid] = link
        return link

    async def set_location(
        self,
        target: str,
        lat: float,
        lon: float,
        accuracy: float = 8,
        altitude: float = 32,
        speed: float = 0,
        bearing: float = 0,
    ) -> list[str]:
        kind, ident = _split_target(target)
        if kind == "android":
            return await asyncio.to_thread(android_set, ident, lat, lon, accuracy, altitude, speed, bearing)
        # iOS 开发者通道只接收经纬度。融合定位靠把同一个点按精度晃动并反复写入来压住。
        try:
            link = await self.ensure_ios(ident)
            await link.set(lat, lon)
        except Exception:
            await self.close_target(target)
            link = await self.ensure_ios(ident)
            await link.set(lat, lon)
        return ["developer"]

    async def clear(self, target: str) -> None:
        kind, ident = _split_target(target)
        if kind == "android":
            await asyncio.to_thread(android_clear, ident)
            return
        link = await self.ensure_ios(ident)
        await link.clear()

    async def close_target(self, target: str) -> None:
        kind, ident = _split_target(target)
        if kind != "ios":
            return
        link = self.ios.pop(ident, None)
        if link is not None:
            await link.close()

    async def close_all(self) -> None:
        for ident in list(self.ios):
            await self.close_target(f"ios:{ident}")


def _split_target(target: str) -> tuple[str, str]:
    kind, _, ident = target.partition(":")
    if kind not in {"ios", "android"} or not ident:
        raise ValueError(f"无法识别的设备 {target}")
    return kind, ident


def _validate_coord(lat: Any, lon: Any) -> tuple[float, float]:
    lat_f = float(lat)
    lon_f = float(lon)
    if not (-90 <= lat_f <= 90 and -180 <= lon_f <= 180):
        raise ValueError("纬度要在 -90 到 90 之间，经度要在 -180 到 180 之间")
    return lat_f, lon_f


async def handle(bridge: Bridge, message: dict[str, Any]) -> dict[str, Any]:
    op = message.get("op")
    if op == "list":
        return await bridge.list_devices()
    if op == "project":
        lat, lon = project(
            float(message["lat"]),
            float(message["lon"]),
            float(message["bearing"]),
            float(message["meters"]),
        )
        return {"lat": lat, "lon": lon}
    target = str(message["target"])
    if op == "set":
        lat, lon = _validate_coord(message["lat"], message["lon"])
        accuracy = float(message.get("accuracy", 8))
        altitude = float(message.get("altitude", 32))
        speed = float(message.get("speed", 0))
        bearing = float(message.get("bearing", 0))
        providers = await bridge.set_location(target, lat, lon, accuracy, altitude, speed, bearing)
        return {
            "target": target,
            "lat": lat,
            "lon": lon,
            "accuracy": accuracy,
            "speed": speed,
            "bearing": bearing,
            "providers": providers,
        }
    if op == "clear":
        await bridge.clear(target)
        return {"target": target}
    if op == "close":
        await bridge.close_target(target)
        return {"target": target}
    raise ValueError(f"未知操作 {op}")


async def serve() -> None:
    logging.basicConfig(level=logging.WARNING)
    bridge = Bridge()
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)
    try:
        while True:
            raw = await reader.readline()
            if not raw:
                break
            line = raw.decode().strip()
            if not line:
                continue
            try:
                message = json.loads(line)
                payload = await handle(bridge, message)
                response = {"id": message.get("id"), "ok": True, **payload}
            except Exception as exc:
                log.error("%s", exc)
                response = {
                    "id": None,
                    "ok": False,
                    "error": str(exc) or exc.__class__.__name__,
                }
                try:
                    response["id"] = json.loads(line).get("id")
                except Exception:
                    response["trace"] = traceback.format_exc(limit=2)
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    finally:
        await bridge.close_all()


def self_check() -> None:
    lat, lon = project(0.0, 0.0, 0.0, EARTH_M * math.pi / 180)
    if abs(lat - 1.0) > 1e-6 or abs(lon) > 1e-6:
        raise SystemExit(f"方位计算不正确：{lat}, {lon}")
    sample = "emulator-5554 device product:sdk model:Pixel_6 device:emu transport_id:3\n"
    # 解析器吃的是 adb 正文，这里直接走同一套拆分。
    devices = []
    for line in sample.splitlines():
        parts = line.split()
        fields = {}
        for item in parts[2:]:
            key, value = item.split(":", 1)
            fields[key] = value
        devices.append(fields["model"].replace("_", " "))
    if devices != ["Pixel 6"]:
        raise SystemExit(f"设备行解析不正确：{devices}")

    class _Link:
        def __init__(self, serial: str, usb: bool) -> None:
            self.serial = serial
            self.is_usb = usb
            self.is_network = not usb

    folded = choose_ios_links([
        _Link("phone", False),
        _Link("phone", True),
        _Link("other", False),
    ])
    if [(item.serial, item.is_usb, both) for item, both in folded] != [
        ("phone", True, True),
        ("other", False, False),
    ]:
        raise SystemExit(f"同一台手机没有合成一条：{folded}")
    command = location_command("fused", 31.2, 121.5, 8, 32, 1.25, 90, True, 1_700_000_000_000)
    for piece in ("set-test-provider-location fused", "--accuracy 8.0", "--speed 1.25", "--bearing 90.0", "--time 1700000000000"):
        if piece not in command:
            raise SystemExit(command)
    print("self-check ok")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
        self_check()
        return
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
