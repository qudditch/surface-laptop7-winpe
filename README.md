# Surface Laptop 7 (Snapdragon X Elite) — Windows 11 26H2 클린 설치 키트

[caccialdo의 가이드](https://gist.github.com/caccialdo/3b0d0113489ecee456d94c1e9462d755)와
댓글에서 확인된 내용을 바탕으로 만든 **WinPE + 설치 미디어** 제작 도구입니다.
가이드와의 가장 큰 차이는 **Surface/Qualcomm 드라이버를 WinPE에 오프라인 통합**해서,
WinPE로 부팅했을 때 내장 키보드·터치패드가 동작하도록 한 점입니다.

```
WinPE\
├─ install.esd                     ← 지금 쓰는 26H2 이미지 (교체 가능)
├─ drivers\SurfaceLaptop7\         ← Surface Laptop 7 드라이버 패키지 (MSI + SurfaceUpdate)
├─ scripts\
│   ├─ Build-WinPE.ps1             ← WinPE(ARM64) 빌드 + ISO 생성
│   ├─ Verify-WinPE.ps1            ← 완성된 boot.wim에 입력 드라이버가 들어갔는지 검사
│   ├─ winpe-drivers.txt           ← WinPE에 넣을 드라이버 목록 (데이터, 자유롭게 편집)
│   ├─ New-InstallMedia.ps1        ← NTFS 설치 USB 내용물 생성/굽기
│   ├─ CreatePartitions.txt        ← diskpart 파티션 레이아웃
│   ├─ ApplyImage.bat              ← WinPE에서 이미지 적용 (esd/wim/swm 자동 인식)
│   ├─ Install-Drivers.ps1         ← 설치 후 드라이버 패키지 설치 (선택)
│   └─ READ-ME-KO.txt              ← 설치 USB에 같이 복사되는 짧은 안내
├─ tools\                          ← 개발용 점검 스크립트 (배포와 무관)
└─ out\                            ← 빌드 결과물 (ISO, 로그, 설치 미디어 스테이징)
```

---

## 0. 준비물

* Windows ADK + **Windows PE add-on** (ARM64 WinPE가 포함된 버전).
  이 PC에는 `C:\Program Files (x86)\Windows Kits\10\...` (WinPE 26100)이 설치되어 있습니다.
* 관리자 권한 PowerShell.
* USB 2개 (가이드와 동일):
  * **WinPE USB** — FAT32, 1 GB 이상
  * **설치 USB** — **NTFS**, 16 GB 이상 권장
    (스테이징 결과 실측 약 **7.2 GB**: `install.esd` 5.6 GB + 드라이버 1.5 GB)
* Surface Laptop 7 본체.

> 이 저장소에는 **`install.esd`와 `drivers\`가 포함되어 있지 않습니다**
> (전자는 수 GB의 Windows 이미지, 후자는 Microsoft 라이선스 드라이버 패키지).
> 직접 준비해 워크스페이스 루트의 `install.esd`, `drivers\SurfaceLaptop7\`에 넣으면
> 스크립트가 그대로 찾습니다.

> WinPE USB는 FAT32여야 UEFI가 읽습니다. 설치 USB는 4 GB를 넘는 ESD 때문에
> 반드시 NTFS여야 하므로, 가이드처럼 **스틱 2개**를 쓰는 구성이 가장 안전합니다.

---

## 1. WinPE 빌드

관리자 PowerShell에서:

```powershell
cd C:\WinPE        rem 이 키트를 풀어 놓은 폴더
powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinPE.ps1
```

스크립트가 하는 일:

1. ADK의 `copype arm64`로 깨끗한 WinPE 작업 폴더 생성
2. `boot.wim` 마운트
3. **`mshidkmdf`**(HID KMDF 프레임워크)를 `install.esd`에서 추출해 WinPE에 추가
   — ADK WinPE에는 `mshidkmdf.sys`는 있지만 **`mshidkmdf.inf`가 없어서**,
   그대로 두면 내장 키보드 드라이버(`SurfaceHidMiniDriver`)의
   `Include=mshidkmdf.inf` 를 해석하지 못해 설치가 실패합니다.
   스크립트는 `.inf`만 추가하고, 이미 있는 `.sys`는 건드리지 않습니다.
   DISM은 ESD를 직접 마운트할 수 없으므로, **처음 한 번만** `install.esd`를
   임시 WIM으로 내보내는 단계가 있습니다(10~20분, 약 7 GB 임시 공간).
   추출한 `mshidkmdf`는 `out\cache`에 캐시되어 다음 빌드부터는 생략됩니다.
4. `scripts\winpe-drivers.txt`에 나열된 Surface/Qualcomm 드라이버를 DISM으로 주입
   (키보드·터치패드·터치스크린·I2C/SPI/GPIO/PMIC/USB/SSH 스택)
5. WinPE 스크래치 공간을 1024 MB로 설정 (6 GB ESD 적용 대비)
6. `boot.wim` 커밋 후 `out\WinPE_SurfaceLaptop7_arm64.iso` 생성

결과물:

```
out\WinPE_SurfaceLaptop7_arm64.iso
out\logs\Build-WinPE_<시각>.log
out\logs\dism-add-driver.log
```

### WinPE USB 만들기

* **Rufus 사용**: `WinPE_SurfaceLaptop7_arm64.iso`를 선택,
  파티션 방식 **GPT**, 대상 **UEFI (non-CSM)**, 파일 시스템 **FAT32**로 굽습니다.
* **스크립트로 바로 쓰기** (해당 USB **전체**가 지워집니다):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinPE.ps1 -UsbDrive P: -Force
```

  지정한 드라이브의 디스크를 `GPT` + **2 GB EFI 시스템 파티션(FAT32, WINPE)** 으로
  다시 만들고 미디어를 복사합니다. ADK의 `MakeWinPEMedia /UFD`는 기존 볼륨을
  포맷하고 `active` 표시만 하기 때문에, 이미 GPT인 USB에서는
  `지정한 디스크는 MBR 형식의 디스크가 아닙니다` 오류로 실패합니다.

### 빌드 결과 검증

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Verify-WinPE.ps1
```

`boot.wim`을 읽기 전용으로 마운트해서 `mshidkmdf`, `surfacehidmini`,
`surfaceserialhubdriver`, Qualcomm I2C/SPI/GPIO 패키지가 실제로 들어갔는지
OK/MISSING으로 출력합니다. ISO를 굽기 전에 한 번 돌려 보세요.

### 드라이버 목록 바꾸기

`scripts\winpe-drivers.txt`는 폴더 이름 한 줄에 하나씩 적는 텍스트 파일입니다.
새 Surface 드라이버 패키지가 나오면 `drivers\...\SurfaceUpdate`에 풀어 넣고
목록에 폴더명을 추가한 뒤 다시 빌드하면 됩니다. `#` 뒤는 주석입니다.

전부 넣고 싶으면:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-WinPE.ps1 -DriverProfile All
```

> `-DriverProfile All`은 178개 패키지를 모두 넣습니다. 부팅 이미지가 커지고
> 일부 패키지는 WinPE에 없는 inbox INF(`wudfrd.inf` 등)를 참조해 실패할 수 있습니다.
> 기본값(Manifest)은 입력 장치에 필요한 패키지만 골라 넣습니다.

---

## 2. 설치 USB 만들기

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\New-InstallMedia.ps1
```

`out\InstallMedia\`에 다음이 스테이징됩니다.

```
install.esd
ApplyImage.bat
CreatePartitions.txt
Install-Drivers.ps1
READ-ME-KO.txt
drivers\SurfaceLaptop7\...
```

이 폴더를 **NTFS로 포맷한 USB**에 그대로 복사하면 됩니다.
스크립트가 포맷까지 하게 하려면(대상 USB가 지워집니다):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\New-InstallMedia.ps1 -UsbDisk 1 -Force
```

(`-UsbDisk` 번호는 `Get-Disk`로 확인. 시스템 디스크는 거부합니다.)

> **USB 하나로 둘 다 쓰고 싶다면**: WinPE USB를 만들면 2 GB EFI 파티션만 쓰고
> 나머지는 할당되지 않은 채로 남습니다. 남은 공간에 NTFS 파티션을 만들어
> `out\InstallMedia`를 복사하면 됩니다. 단, Windows/WinPE는 이동식 디스크의
> **첫 번째 파티션만 자동으로 문자를 할당**하므로, WinPE에서 그 파티션이 안 보이면
> `diskpart` → `list volume` → `select volume N` → `assign` 으로 문자를 주면 됩니다.

### install.esd 교체 (유동성)

새 `install.esd`를 워크스페이스에 넣고 **2단계만 다시 실행**하면 됩니다.
`ApplyImage.bat`이 `install.esd` / `install.wim` / `install*.swm`을 자동으로 찾고,
실행할 때 이미지 인덱스 목록을 보여 주고 선택하게 합니다. WinPE 재빌드는 필요 없습니다.

```powershell
.\scripts\New-InstallMedia.ps1 -Image D:\새이미지\install.esd
```

(선택) WinPE에 넣을 `mshidkmdf`도 새 이미지에서 뽑도록 캐시를 지우려면
`out\cache\mshidkmdf` 폴더를 삭제한 뒤 WinPE를 다시 빌드하세요.

---

## 3. Surface에서 설치

1. Surface를 완전히 종료합니다.
2. **Vol Down 키를 누른 채로 전원 버튼을 눌렀다 떼면** USB 부팅 메뉴로 들어갑니다.
   (Vol Up + 전원은 UEFI 설정. UEFI에서 `Boot configuration` → USB를 맨 위로 올려도 됩니다.)
3. 두 USB( WinPE + 설치 )를 연결하고 WinPE로 부팅합니다.
   Secure Boot는 켜 둔 상태로 두어도 됩니다(모두 Microsoft 서명 부팅 파일).
   만약 펌웨어가 2011 UEFI CA를 신뢰하지 않아 부팅이 거부되면
   `Build-WinPE.ps1 -UseExBootManager`로 다시 빌드해 보세요
   (2023 CA로 서명된 부팅 관리자를 사용합니다).
4. 파란 명령 프롬프트가 뜨면:

```bat
diskpart
list disk
exit
```

내장 NVMe가 **disk 0**, USB가 disk 1인지 확인합니다.

```bat
diskpart /s D:\CreatePartitions.txt
```

> `D:`는 설치 USB의 실제 드라이브 문자로 바꾸세요. 이 단계에서 **disk 0 전체가 지워집니다.**

```bat
D:\ApplyImage.bat
```

* 이미지 인덱스 목록이 나오면 적용할 번호를 입력합니다(기본 1).
* 필요하면 `D:\ApplyImage.bat D:\install.esd 3` 처럼 파일/인덱스를 직접 지정할 수 있습니다.

5. 완료되면:

```bat
wpeutil shutdown
```

6. USB를 뽑고 정상 부팅 → Windows 11 OOBE가 시작됩니다.

### ApplyImage.bat 옵션

| 인자 | 설명 |
|---|---|
| `[이미지경로]` | `install.esd` / `.wim` / `.swm` 지정 (생략 시 자동 탐색) |
| `[인덱스]` | 적용할 이미지 인덱스 (생략 시 목록 출력 후 질문) |
| `/drivers` | `drivers\` 전체를 오프라인 이미지(`W:\`)에 추가 주입 |
| `/copyimage` | 가이드 원문처럼 이미지를 `R:\`에도 복사 (15 GB 파티션 사용) |

기본값은 `/drivers`와 `/copyimage` 모두 **꺼짐**입니다. 26H2 이미지 자체에
Surface 입력 드라이버가 이미 들어 있어서 첫 부팅에 문제가 없고, 이미지 복사는
설치 시간만 늘리기 때문입니다. 드라이버를 이미지에 확실히 박아 두고 싶으면
`D:\ApplyImage.bat D:\install.esd 1 /drivers`로 실행하세요.

---

## 4. 설치 후 (선택)

OOBE에서 네트워크가 필요하거나, 오디오·카메라 등 나머지 구성 요소를 설치하려면
설치 USB의 `Install-Drivers.ps1`을 관리자 PowerShell에서 실행합니다.

```powershell
powershell -ExecutionPolicy Bypass -File E:\Install-Drivers.ps1 -RunMsi
```

`-RunMsi`는 Surface MSI(서비스/소프트웨어 구성 요소 포함)까지 실행합니다.

---

## 5. 문제 해결

* **WinPE에서 내장 키보드/터치패드가 안 될 때**
  * 먼저 USB 키보드/마우스로 조작할 수 있습니다.
  * WinPE 안에서 `X:\Windows\System32\WinPE-DriverReport.cmd`를 실행하면
    추가된 드라이버 목록, HID/키보드/마우스 장치 상태, 디스크 목록이 출력됩니다.
  * `X:\Windows\System32\wpeinit.log`에서 드라이버 로드 오류를 확인할 수 있습니다.
  * 빌드 로그(`out\logs\dism-add-driver.log`)에서 필수 패키지 주입 실패가 없는지 확인하세요.
    `hidmini`, `surfaceserialhubdriver`, `qci2c8380`, `qcspi8380`, `qcgpio8380`,
    `qcpmicgpio8380`은 실패 시 빌드가 중단되도록 해 두었습니다.
* **`W:`가 없다고 나올 때** — `CreatePartitions.txt`를 먼저 실행했는지, USB 문자를
  잘못 지정하지 않았는지 확인하세요.
* **`reagentc` 경고** — WinRE 등록만 실패한 경우이며 설치는 정상입니다.
  부팅 후 `reagentc /enable`로 다시 등록할 수 있습니다.
* **이미지 인덱스** — 26H2 ESD에 Home/Pro 등 여러 인덱스가 있으면 목록에서 고르면 됩니다.

---

## 6. 가이드와 다른 점 (의도된 변경)

| 항목 | 가이드 | 이 키트 | 이유 |
|---|---|---|---|
| WinPE 드라이버 | 없음 (USB 마우스/이더넷 의존) | Surface/Qualcomm 입력·플랫폼 드라이버 주입 | WinPE에서 내장 키보드/터치패드 사용 |
| WinRE 파티션 | 600 MB | **1024 MB** | 26H2 `winre.wim`이 약 783 MB라 600 MB에는 복사 실패 |
| Windows 파티션 축소 | `shrink` 후 `format` | `format` 후 `shrink` | diskpart는 포맷된 볼륨만 축소 가능 |
| 이미지 형식 | `install.wim` | `install.esd` / `.wim` / `.swm` 자동 | 사용자가 만든 ESD 지원 |
| 이미지 인덱스 | 1 고정 | 목록 출력 후 선택 | ESD 교체 시 유동적 |
| `R:` 이미지 복사 | 항상 | `/copyimage` 옵션 (기본 꺼짐) | 설치 시간 절약, 실사용 효과 없음 |
| 드라이버 사전 주입 | 없음 | `/drivers` 옵션 (기본 꺼짐) | 26H2 이미지에 이미 포함, 필요 시 선택 |

---

## 7. 참고: 이 이미지에 대해 확인한 사실

* `install.esd`(26H2, ARM64)의 DriverStore에 **SurfaceHidMiniDriver,
  SurfaceSerialHubDriver, SurfaceIntegrationDriver, SurfaceHIDFriendlyNames**가
  이미 포함되어 있습니다. 즉 설치된 Windows의 첫 부팅부터 내장 키보드/터치패드
  드라이버가 존재합니다.
* ADK WinPE(26100)에는 **`hidi2c`, `hidspi`, `SpbCx`, `input.inf`,
  `keyboard.inf`, `msmouse.inf`, 그리고 Qualcomm `qci2c_i`/`qcgpio_i`** 가
  들어 있습니다. `mshidkmdf.sys`도 `System32\drivers`에 있지만
  **`mshidkmdf.inf`가 빠져 있어** `Include=mshidkmdf.inf`가 실패합니다.
  그래서 빌드 스크립트가 설치 이미지에서 `.inf`를 추출해 `Windows\INF`에 넣습니다.
  (마운트된 WIM 안의 기존 `.sys`는 SYSTEM 소유 reparse 항목이라 덮어쓸 수 없고,
  덮어쓸 필요도 없습니다.)
* WinPE에는 `wudfrd.inf`가 없어 UMDF 기반 패키지(`surfacecfuoverhid`, `qcdcf`)는
  기본 목록에서 제외했습니다. 입력 동작과는 무관합니다.
* `SurfaceHidMiniDriver.inf`는 `Include=mshidkmdf.inf`,
  `Needs=mshidkmdf.NT.Services`를 쓰고, 서비스 바이너리는
  `%10%\System32\Drivers\mshidkmdf.sys`입니다. 그래서 `.inf`(해석용)와
  `.sys`(실행 파일)가 **둘 다** 이미지에 있어야 합니다.

---

## 8. 이 키트로 실제 빌드한 결과 (2026-10-23)

| 항목 | 값 |
|---|---|
| 드라이버 주입 | **70 / 70 성공** (실패 0) |
| `boot.wim` | 342 MB |
| `out\WinPE_SurfaceLaptop7_arm64.iso` | 374 MB |
| DriverStore 패키지 수 | 291 |
| `out\InstallMedia` | 7.2 GB |

`Verify-WinPE.ps1`로 최종 ISO를 검사한 출력:

```
  OK      Windows\INF\mshidkmdf.inf
  OK      Windows\System32\drivers\mshidkmdf.sys
  OK      qcgpio8380                 GPIO controller
  OK      qci2c8380                  I2C controller
  OK      qcpmicgpio8380             PMIC GPIO
  OK      qcspi8380                  SPI controller (touchpad)
  OK      surfacehidmini             built-in keyboard
  OK      surfaceintegrationdriver   Surface integration
  OK      surfaceserialhubdriver     keyboard transport (SSH)
  OK      mshidkmdf                  HID KMDF package
  total packages in driver store: 291
RESULT: OK - the built-in keyboard/touchpad stack is present.
```

> 2025-05 이후 나온 Surface 드라이버 패키지(SurfaceUpdate 26.091.9400.0)를 기준으로
> 한 결과입니다. 드라이버 패키지를 교체하면 `Verify-WinPE.ps1`을 다시 돌려 확인하세요.
