# Sending Images to G2 Display

## Overview
The G2 glasses have a micro-LED display that can render images, text, and graphics. The app renders content as 4-bit grayscale BMP images and sends them via BLE.

---

## BLE Addresses

| UUID Suffix | Full UUID | Direction | Purpose |
|-------------|-----------|-----------|---------|
| `5401` | `00002760-08C2-11E1-9073-0E8AC72E5401` | Write | Page management commands |
| `5402` | `00002760-08C2-11E1-9073-0E8AC72E5402` | Notify | Command acknowledgments |
| `6401` | `00002760-08C2-11E1-9073-0E8AC72E6401` | Write | Display data transfer |
| `6402` | `00002760-08C2-11E1-9073-0E8AC72E6402` | Write | Display rendering data |

---

## Display Specifications

- **Width**: ~267px (from community protocol docs)
- **Color depth**: 4-bit grayscale (16 levels of gray)
- **Format**: Compressed BMP
- **Pixel format**: `gray4bit`, `PixelUint4`

---

## Image Format

### 4-Bit Grayscale BMP

The app encodes all display content as 4-bit grayscale BMP images:

1. **Render** content to a canvas (text, shapes, images)
2. **Encode** to 4-bit BMP: `_encodeBmp4bit` → `bmpEncode`
3. **Compress**: `compressBmpData` — reduces transfer size
4. **Transfer** via BLE file service

### Encoding Functions (from app)
- `_encodeBmp4bit@2483147500` — main BMP 4-bit encoder
- `_stepBmpEncode@2483147500` — step-wise BMP encoding
- `_getPixelColorIndex@2483147500` — map colors to 4-bit palette
- `compressBmpData` — compress the BMP data
- `Uint8ListExtension|retainPixels` — pixel data handling

### BMP Structure
Standard BMP file format with:
- BMP file header (14 bytes)
- BMP info header (40 bytes)
- 4-bit color palette (16 entries × 4 bytes = 64 bytes)
- Pixel data (4 bits per pixel, rows padded to 4-byte boundary)

---

## Display Protocol

### Page Lifecycle

| Packet Type | Direction | Purpose |
|-------------|-----------|---------|
| `APP_REQUEST_CREATE_STARTUP_PAGE_PACKET` | Phone → Glasses | Create a new display page |
| `OS_RESPONSE_CREATE_STARTUP_PAGE_PACKET` | Glasses → Phone | Acknowledge page creation |
| `APP_UPDATE_IMAGE_RAW_DATA_PACKET` | Phone → Glasses | Send image data |
| `OS_RESPONSE_IMAGE_RAW_DATA_PACKET` | Glasses → Phone | Acknowledge image received |
| `APP_REQUEST_REBUILD_PAGE_PACKET` | Phone → Glasses | Refresh/rebuild current page |
| `OS_RESPONSE_REBUILD_PAGE_PACKET` | Glasses → Phone | Acknowledge rebuild |
| `APP_REQUEST_SHUTDOWN_PAGE_PACKET` | Phone → Glasses | Clear/close display page |
| `OS_RESPONSE_SHUTDOWN_PAGE_PACKET` | Glasses → Phone | Acknowledge shutdown |

### Image Transfer via File Service

Large images use the Even File Service protocol:

```
1. EVEN_FILE_SERVICE_CMD_SEND_START  → initiate transfer
2. EVEN_FILE_SERVICE_CMD_SEND_DATA   → send data chunks
3. EVEN_FILE_SERVICE_CMD_SEND_RESULT_CHECK → verify transfer
```

Response codes:
- `EVEN_FILE_SERVICE_RSP_SUCCESS` — transfer OK
- `EVEN_FILE_SERVICE_RSP_DATA_CRC_ERR` — CRC mismatch, resend
- `EVEN_FILE_SERVICE_RSP_FLASH_WRITE_ERR` — glasses flash error
- `EVEN_FILE_SERVICE_RSP_NO_RESOURCES` — no memory available
- `EVEN_FILE_SERVICE_RSP_TIMEOUT` — transfer timed out

### Protobuf Classes
- `ImageRawDataUpdate` — image data update message
- `ResponseImageRawDataCmd` — glasses response to image data
- `RebuildPageContainer` — page rebuild container
- `DrawImageData` — draw image command data
- `EvenSendFileBigPackage` — large file transfer packaging

---

## Drawing Commands

The app uses a canvas-based rendering system with serializable draw commands:

### Text Drawing
- `writeDrawText` — serialize text draw command
- `_readDrawText` — deserialize text draw command
- `onDrawText` — execute text drawing
- `_drawText@2189131997` — render text to canvas
- `_drawTextWithFont@3033463121` — render with specific font
- `_drawTextWithGlyphs@3033463121` — render with glyph data

### Image Drawing
- `writeDrawImage` — serialize image draw command
- `_readDrawImage` — deserialize image draw command
- `onDrawImage` — execute image drawing
- `_drawImageScaledAndCentered` — draw scaled/centered image
- `_buildDisplayImageArea` — prepare display image area
- `_getDisplayImage` — get current display image

### Shape Drawing
- `drawLine` / `drawRect` — basic shapes
- Canvas operations: clip, rotate, scale, translate

---

## Display Data Flow

### Sending a Static Image
```
1. Prepare image as 4-bit grayscale BMP (267px wide, 16 gray levels)
2. Compress with BMP compression
3. Create startup page: APP_REQUEST_CREATE_STARTUP_PAGE_PACKET → 5401
4. Wait for OS_RESPONSE_CREATE_STARTUP_PAGE_PACKET on 5402
5. Send image data: APP_UPDATE_IMAGE_RAW_DATA_PACKET → 6401/6402
   - If large: use file service (SEND_START → SEND_DATA → RESULT_CHECK)
6. Wait for OS_RESPONSE_IMAGE_RAW_DATA_PACKET on 5402
```

### Updating Display Content
```
1. Prepare new image/content
2. Send APP_REQUEST_REBUILD_PAGE_PACKET → 5401
3. Send updated image data → 6401/6402
4. Wait for acknowledgment
```

### Clearing Display
```
1. Send APP_REQUEST_SHUTDOWN_PAGE_PACKET → 5401
2. Wait for OS_RESPONSE_SHUTDOWN_PAGE_PACKET
```

---

## Display Content Filtering

The app has a `GlassesDisplayDataFilter` system:
- `glassesDisplayDataFilterKey` — storage key for filter settings
- `setGlassesDisplayDataFilter` — configure what content to show
- Filters control which services can write to the display

---

## Implementation on Mac

### Sending a Custom Image
```python
# Pseudocode
1. Load/create image (PNG, JPEG, etc.)
2. Resize to ~267px wide (maintain aspect ratio)
3. Convert to 4-bit grayscale (16 levels)
4. Encode as BMP with 4-bit palette
5. Optionally compress
6. Connect to G2 glasses, authenticate
7. Send CREATE_STARTUP_PAGE command on 5401
8. Send image data on 6401/6402 using file service protocol
9. Verify with RESULT_CHECK
```

### Image Encoding (Python example)
```python
from PIL import Image
import struct

def encode_4bit_grayscale_bmp(image_path, width=267):
    img = Image.open(image_path).convert('L')  # grayscale
    img = img.resize((width, int(img.height * width / img.width)))

    # Quantize to 16 levels
    img = img.quantize(colors=16)

    # Build 4-bit BMP (standard BMP format)
    # ... BMP header + 16-color palette + 4-bit pixel data
```

---

## What Needs BLE Snoop Capture
- Exact packet format for CREATE_STARTUP_PAGE command
- Whether images go on `6401` or `6402` (or both)
- File service command protobuf structure
- BMP compression algorithm used by `compressBmpData`
- Maximum image dimensions the display supports
- Whether the display supports partial updates
