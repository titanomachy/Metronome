## Access to Metronome's generated, embedded IANA timezone catalog.

import std/os

type
  BlobRange = object
    start: int
    length: int

  CatalogEntry = object
    name: string
    blobIndex: int

  Catalog = object
    content: string
    blobs: seq[BlobRange]
    entries: seq[CatalogEntry]
    dataVersion: string
    zicVersion: string

  Cursor = object
    content: string
    position: int

const
  CatalogMagic = "MTZDB001"
  DataFile = currentSourcePath.parentDir / "data" / "2026c.tzdb"
  EmbeddedCatalog = staticRead(DataFile)

proc require(cursor: Cursor, count: int) =
  doAssert count >= 0 and cursor.position <= cursor.content.len - count,
    "Invalid embedded timezone catalog"

proc readByte(cursor: var Cursor): int =
  cursor.require(1)
  result = ord(cursor.content[cursor.position])
  inc cursor.position

proc readUint16(cursor: var Cursor): int =
  cursor.require(2)
  result = (cursor.readByte() shl 8) or cursor.readByte()

proc readUint32(cursor: var Cursor): int =
  cursor.require(4)
  var value: uint32
  for _ in 0..<4:
    value = (value shl 8) or uint32(cursor.readByte())
  doAssert value <= uint32(high(int)), "Invalid embedded timezone catalog"
  int(value)

proc readString(cursor: var Cursor, length: int): string =
  cursor.require(length)
  result = cursor.content[cursor.position ..< cursor.position + length]
  cursor.position += length

proc readShortString(cursor: var Cursor): string =
  cursor.readString(cursor.readByte())

proc parseCatalog(content: string): Catalog =
  var cursor = Cursor(content: content)
  doAssert cursor.readString(CatalogMagic.len) == CatalogMagic,
    "Invalid embedded timezone catalog"

  result.content = content
  result.dataVersion = cursor.readShortString()
  result.zicVersion = cursor.readShortString()

  let blobCount = cursor.readUint32()
  result.blobs = newSeq[BlobRange](blobCount)
  for index in 0..<blobCount:
    let length = cursor.readUint32()
    result.blobs[index] = BlobRange(start: cursor.position, length: length)
    cursor.require(length)
    cursor.position += length

  let entryCount = cursor.readUint32()
  result.entries = newSeq[CatalogEntry](entryCount)
  var previousName = ""
  for index in 0..<entryCount:
    let name = cursor.readString(cursor.readUint16())
    let blobIndex = cursor.readUint32()
    doAssert blobIndex < result.blobs.len,
      "Invalid embedded timezone catalog"
    doAssert index == 0 or name > previousName,
      "Embedded timezone names must be sorted and unique"
    result.entries[index] = CatalogEntry(name: name, blobIndex: blobIndex)
    previousName = name

  doAssert cursor.position == content.len, "Invalid embedded timezone catalog"

let catalog = parseCatalog(EmbeddedCatalog)

proc catalogDataVersion*(): string {.inline, raises: [].} =
  catalog.dataVersion

proc catalogZicVersion*(): string {.inline, raises: [].} =
  catalog.zicVersion

proc catalogNames*(): seq[string] {.raises: [].} =
  result = newSeq[string](catalog.entries.len)
  for index, entry in catalog.entries:
    result[index] = entry.name

proc catalogZone*(name: string): string {.raises: [].} =
  var low = 0
  var high = catalog.entries.high
  while low <= high:
    let middle = low + (high - low) div 2
    let entry = catalog.entries[middle]
    if name == entry.name:
      let blob = catalog.blobs[entry.blobIndex]
      return catalog.content[blob.start ..< blob.start + blob.length]
    if name < entry.name:
      high = middle - 1
    else:
      low = middle + 1
