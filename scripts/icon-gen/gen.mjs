/*
 * AikoBox icon set generator.
 *
 * Source artwork: a 640x963 portrait illustration (face in the top third, vivid
 * yellow background). This script square-crops it (top-biased so the face is
 * well framed), renders a 1024x1024 master, and overwrites every app icon in
 * build/ and resources/ (except build/background.png, which is intentionally
 * left alone).
 *
 * Usage:  node gen.mjs [--top N]     (N = source-pixel Y offset of the square
 *                                     crop, default CROP_TOP below)
 *
 * Outputs
 *   scripts/icon-gen/master-1024.png            1024x1024 master
 *   build/icon.png                              512x512
 *   build/icon.ico, build/installerIcon.ico     16/24/32/48/64/128/256
 *   build/icon.icns                             png2icons full size set
 *   resources/icon.png                          512x512 (matches original)
 *   resources/icon.ico                          32/64/128/256 (matches original)
 *   resources/icon_{blue,green,red}.{png,ico}   base + colored status badge
 *   resources/iconTemplate.png                  64x64 macOS template image
 */

import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import sharp from 'sharp'
import png2icons from 'png2icons'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..', '..')
const SOURCE = 'D:/PICCC/stelle-caelus-by-roha-v0-ikbaycbyrvcd1.jpeg'

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------
const CROP_TOP = 0 // top edge (source px) of the 640x640 square crop
const MASTER_SIZE = 1024
const BUILD_PNG_SIZE = 512 // original build/icon.png is 512x512
const RES_PNG_SIZE = 512 // original resources/*.png are 512x512
const TEMPLATE_SIZE = 64 // original resources/iconTemplate.png is 64x64
const BUILD_ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
const RES_ICO_SIZES = [32, 64, 128, 256] // sizes present in the original .ico set

// Tray status badge (bottom-right filled circle with a thin white ring)
const BADGE_COLORS = { blue: '#3b82f6', green: '#22c55e', red: '#ef4444' }
const BADGE_DIAMETER = 0.35 // fraction of canvas
const BADGE_RING = 0.022 // white ring stroke width, fraction of canvas
const BADGE_PAD = 0.02 // gap to the canvas edges, fraction of canvas

const args = process.argv.slice(2)
const topArg = args.indexOf('--top')
const cropTop = topArg >= 0 ? Number(args[topArg + 1]) : CROP_TOP

// ---------------------------------------------------------------------------
// ICO packer: 32bpp BMP (DIB) entries for sizes < 256, embedded PNG for 256.
// ---------------------------------------------------------------------------
function encodeIcoBmp(size, rgba) {
  const w = size
  const h = size
  const xorStride = w * 4
  const andStride = ((w + 31) >> 5) << 2 // 1bpp mask rows padded to 32 bits
  const header = Buffer.alloc(40)
  header.writeUInt32LE(40, 0) // biSize
  header.writeInt32LE(w, 4) // biWidth
  header.writeInt32LE(h * 2, 8) // biHeight = XOR + AND
  header.writeUInt16LE(1, 12) // biPlanes
  header.writeUInt16LE(32, 14) // biBitCount
  header.writeUInt32LE(0, 16) // biCompression = BI_RGB
  header.writeUInt32LE(xorStride * h + andStride * h, 20) // biSizeImage
  const xor = Buffer.alloc(xorStride * h)
  for (let y = 0; y < h; y++) {
    const src = (h - 1 - y) * xorStride // DIB rows are bottom-up
    const dst = y * xorStride
    for (let x = 0; x < w; x++) {
      const s = src + x * 4
      const d = dst + x * 4
      xor[d] = rgba[s + 2] // B
      xor[d + 1] = rgba[s + 1] // G
      xor[d + 2] = rgba[s] // R
      xor[d + 3] = rgba[s + 3] // A
    }
  }
  const and = Buffer.alloc(andStride * h) // fully "opaque"; real alpha is 32bpp
  return Buffer.concat([header, xor, and])
}

async function buildIco(basePng, sizes, outFile) {
  const entries = []
  for (const size of sizes) {
    const resized = sharp(basePng).resize(size, size, { kernel: 'lanczos3' }).ensureAlpha()
    if (size >= 256) {
      entries.push({ size, data: await resized.png({ compressionLevel: 9 }).toBuffer() })
    } else {
      entries.push({ size, data: encodeIcoBmp(size, await resized.raw().toBuffer()) })
    }
  }
  const dir = Buffer.alloc(6)
  dir.writeUInt16LE(0, 0) // reserved
  dir.writeUInt16LE(1, 2) // type = icon
  dir.writeUInt16LE(entries.length, 4)
  let offset = 6 + 16 * entries.length
  const dirEntries = []
  const blobs = []
  for (const { size, data } of entries) {
    const e = Buffer.alloc(16)
    e.writeUInt8(size >= 256 ? 0 : size, 0) // width (0 = 256)
    e.writeUInt8(size >= 256 ? 0 : size, 1) // height
    e.writeUInt16LE(1, 4) // planes
    e.writeUInt16LE(32, 6) // bit count
    e.writeUInt32LE(data.length, 8)
    e.writeUInt32LE(offset, 12)
    offset += data.length
    dirEntries.push(e)
    blobs.push(data)
  }
  await writeFile(outFile, Buffer.concat([dir, ...dirEntries, ...blobs]))
}

// ---------------------------------------------------------------------------
// Status badge overlay (inline SVG, composited by sharp)
// ---------------------------------------------------------------------------
function badgeOverlay(color) {
  const S = MASTER_SIZE
  const d = S * BADGE_DIAMETER
  const ring = S * BADGE_RING
  const pad = S * BADGE_PAD
  const c = S - pad - d / 2 // circle center (x == y), bottom-right corner
  const r = (d - ring) / 2 // stroke straddles r, so the outer edge is d/2
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}">` +
      `<circle cx="${c}" cy="${c}" r="${r}" fill="${color}" stroke="#ffffff" stroke-width="${ring}"/>` +
      `</svg>`
  )
}

// ---------------------------------------------------------------------------
// macOS menu-bar template image: pure black + alpha. The yellow background is
// keyed out by chroma distance (its luminance overlaps the shirt's, so
// luminance alone cannot separate them); inside the silhouette the alpha is
// driven by source luminance (dark -> opaque) with a floor so bright regions
// (shirt, skin, hair) still read at 16pt.
// ---------------------------------------------------------------------------
async function makeTemplate(masterPng) {
  const N = 256 // work at 256, then downscale for anti-aliased edges
  const { data } = await sharp(masterPng)
    .resize(N, N, { kernel: 'lanczos3' })
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true })
  const px = (x, y) => {
    const i = (y * N + x) * 3
    return [data[i], data[i + 1], data[i + 2]]
  }
  // background reference = average of the two top corners (always yellow bg)
  const c1 = px(4, 4)
  const c2 = px(N - 5, 4)
  const bg = [(c1[0] + c2[0]) / 2, (c1[1] + c2[1]) / 2, (c1[2] + c2[2]) / 2]
  const out = Buffer.alloc(N * N * 4)
  for (let i = 0, p = 0; i < data.length; i += 3, p += 4) {
    const r = data[i]
    const g = data[i + 1]
    const b = data[i + 2]
    const dist = Math.hypot(r - bg[0], g - bg[1], b - bg[2])
    let sil = (dist - 30) / 80 // smoothstep between 30 and 110
    sil = Math.max(0, Math.min(1, sil))
    sil = sil * sil * (3 - 2 * sil)
    const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    const shade = 0.35 + 0.65 * (1 - lum) // luminance-derived opacity w/ floor
    out[p + 3] = Math.round(255 * sil * shade) // RGB stays 0 (black)
  }
  return sharp(out, { raw: { width: N, height: N, channels: 4 } })
    .resize(TEMPLATE_SIZE, TEMPLATE_SIZE, { kernel: 'lanczos3' })
    .png()
    .toBuffer()
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const src = sharp(SOURCE)
  const meta = await src.metadata()
  console.log(`source ${SOURCE}: ${meta.width}x${meta.height}`)
  const cropSize = Math.min(meta.width, meta.height)
  const top = Math.max(0, Math.min(cropTop, meta.height - cropSize))
  console.log(`crop: ${cropSize}x${cropSize}+0+${top} -> master ${MASTER_SIZE}x${MASTER_SIZE}`)

  const master = await src
    .extract({ left: 0, top, width: cropSize, height: cropSize })
    .resize(MASTER_SIZE, MASTER_SIZE, { kernel: 'lanczos3' })
    .ensureAlpha()
    .png({ compressionLevel: 9 })
    .toBuffer()
  await writeFile(path.join(HERE, 'master-1024.png'), master)

  const resize = (buf, size) =>
    sharp(buf).resize(size, size, { kernel: 'lanczos3' }).png({ compressionLevel: 9 }).toBuffer()

  // --- build/ (electron-builder resources) ---
  await writeFile(path.join(ROOT, 'build/icon.png'), await resize(master, BUILD_PNG_SIZE))
  await buildIco(master, BUILD_ICO_SIZES, path.join(ROOT, 'build/icon.ico'))
  await buildIco(master, BUILD_ICO_SIZES, path.join(ROOT, 'build/installerIcon.ico'))
  const icns = png2icons.createICNS(master, png2icons.BICUBIC, 0)
  if (!icns) throw new Error('png2icons.createICNS returned null')
  await writeFile(path.join(ROOT, 'build/icon.icns'), icns)

  // --- resources/ (runtime window + tray icons) ---
  await writeFile(path.join(ROOT, 'resources/icon.png'), await resize(master, RES_PNG_SIZE))
  await buildIco(master, RES_ICO_SIZES, path.join(ROOT, 'resources/icon.ico'))
  for (const [name, color] of Object.entries(BADGE_COLORS)) {
    const badged = await sharp(master)
      .composite([{ input: badgeOverlay(color) }])
      .png({ compressionLevel: 9 })
      .toBuffer()
    await writeFile(
      path.join(ROOT, `resources/icon_${name}.png`),
      await resize(badged, RES_PNG_SIZE)
    )
    await buildIco(badged, RES_ICO_SIZES, path.join(ROOT, `resources/icon_${name}.ico`))
  }
  await writeFile(path.join(ROOT, 'resources/iconTemplate.png'), await makeTemplate(master))

  // --- verify what landed on disk ---
  console.log('\n--- verification (read back from disk) ---')
  const pngFiles = [
    'scripts/icon-gen/master-1024.png',
    'build/icon.png',
    'resources/icon.png',
    'resources/icon_blue.png',
    'resources/icon_green.png',
    'resources/icon_red.png',
    'resources/iconTemplate.png'
  ]
  for (const f of pngFiles) {
    const m = await sharp(path.join(ROOT, f)).metadata()
    console.log(`${f}: ${m.width}x${m.height} ${m.format} ${m.channels}ch`)
  }
  const icoFiles = [
    'build/icon.ico',
    'build/installerIcon.ico',
    'resources/icon.ico',
    'resources/icon_blue.ico',
    'resources/icon_green.ico',
    'resources/icon_red.ico'
  ]
  for (const f of icoFiles) {
    const b = await readFile(path.join(ROOT, f))
    const n = b.readUInt16LE(4)
    const sizes = []
    for (let i = 0; i < n; i++) {
      const o = 6 + 16 * i
      sizes.push(`${b.readUInt8(o) || 256}@${b.readUInt16LE(o + 6)}bpp`)
    }
    console.log(`${f}: ${n} entries [${sizes.join(', ')}]`)
  }
  const ib = await readFile(path.join(ROOT, 'build/icon.icns'))
  const types = []
  for (let o = 8; o < ib.length; ) {
    const type = ib.toString('ascii', o, o + 4)
    const len = ib.readUInt32BE(o + 4)
    if (type !== 'TOC ') types.push(type)
    o += len
  }
  console.log(
    `build/icon.icns: magic=${ib.toString('ascii', 0, 4)} bytes=${ib.length} chunks=[${types.join(', ')}]`
  )
  console.log('\ndone.')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
