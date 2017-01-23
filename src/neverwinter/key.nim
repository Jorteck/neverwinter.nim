when sizeof(int) < 4: {.fatal: "Only 32/64bit supported." }

import streams, options, sequtils, strutils, tables

import resman, util

type
  ResId = int

  VariableResource = tuple
    id: ResId
    offset: int
    fileSize: int
    resType: ResType

  Bif* = ref object
    keyTable: KeyTable
    filename: string
    io: Stream
    fileType: string
    fileVersion: string

    variableResources: Table[ResId, VariableResource]

  KeyTable* = ref object of ResContainer
    io: Stream
    ioStart: int

    bifs: seq[Bif]
    resrefIdLookup: Table[ResRef, ResId]

proc openBif(io: Stream, owner: KeyTable, filename: string): Bif =
  new(result)

  result.variableResources = initTable[ResId, VariableResource]()
  result.io = io
  result.keyTable = owner
  result.filename = filename

  result.fileType = io.readStrOrErr(4)
  expect(result.fileType == "BIFF")
  result.fileVersion = io.readStrOrErr(4)
  expect(result.fileVersion == "V1  ")

  let varResCount = io.readInt32()
  let fixedResCount = io.readInt32()
  let variableTableOffset = io.readInt32()

  expect(fixedResCount == 0, "fixed resources in bif not supported")

  io.setPosition(variableTableOffset)
  for i in 0..<varResCount:
    let r: VariableResource = (
      id: (io.readInt32() and 0xfffff).ResId,
      offset: io.readInt32().int,
      fileSize: io.readInt32().int,
      resType: io.readInt32().ResType
    )

    result.variableResources[r.id] = r

proc hasResId*(self: Bif, id: ResId): bool =
  self.variableResources.hasKey(id)

proc getVariableResource*(self: Bif, id: ResId): VariableResource =
  self.variableResources[id]

proc getStreamForVariableResource*(self: Bif, id: ResId): Stream =
  result = newFileStream(self.filename)
  result.setPosition(self.variableResources[id].offset)

proc readFromStream*(io: Stream): KeyTable =
  new(result)
  result.io = io
  result.ioStart = io.getPosition
  result.bifs = newSeq[Bif]()

  result.resrefIdLookup = initTable[Resref, ResId]()

  let ioStart = result.ioStart

  let ft = io.readStrOrErr(4)
  expect(ft == "KEY ")
  let fv = io.readStrOrErr(4)
  expect(fv == "V1  ")

  let bifCount = io.readInt32()
  let keyCount = io.readInt32()
  let offsetToFileTable = io.readInt32()
  let offsetToKeyTable = io.readInt32()
  let buildYear = io.readInt32()
  let buildDay = io.readInt32()
  io.setPosition(io.getPosition + 32) # reserved bytes

  const HeaderSize = 64
  assert(io.getPosition == ioStart + HeaderSize)

  # expect(offsetToFileTable > HeaderSize and offsetToFileTable < offsetToKeyTable)

  var fileTable = newSeq[tuple[fSize: int32, fnOffset: int32,
                               fnSize: int16, drives: int16]]()

  io.setPosition(offsetToFileTable)

  for i in 0..<bifCount:
    let fSize = io.readInt32()
    let fnOffset = io.readInt32()
    let fnSize = io.readInt16()
    let drives = io.readInt16()
    # expect(drives == 1, "only drives = 1 supported, but got: " & $drives)
    fileTable.add((fSize, fnOffset, fnSize, drives))

  let filenameTable = fileTable.map(proc (entry: auto): string =
    io.setPosition(ioStart + entry.fnOffset)
    expect(entry.fnSize > 1, "bif filename in filenametable empty")
    result = io.readStrOrErr(entry.fnSize - 1)

    when defined(posix):
      result = result.replace("\\", "/")
  )

  for fn in filenameTable:
    let fnio = newFileStream(fn)
    expect(fnio != nil, "key file referenced file " & fn & " but cannot open")
    result.bifs.add(openBif(fnio, result, fn))

  io.setPosition(offsetToKeyTable)
  for i in 0..<keyCount:
    let resref = io.readStrOrErr(16).strip(true, true, {'\0'})
    let restype = io.readInt16().ResType
    let resId = io.readInt32()
    let bifIdx = resId shr 20
    let bifId = resId and 0xfffff

    expect(bifIdx >= 0 and bifIdx < result.bifs.len)
    expect(result.bifs[bifIdx].hasResId(bifId), "bifId not in bif: " & $bifId)

    let rr: Resref = (resRef: resref, resType: restype)
    result.resrefIdLookup[rr] = resId

method contains*(self: KeyTable, rr: ResRef): bool =
  result = self.resrefIdLookup.hasKey(rr)

method demand*(self: KeyTable, rr: ResRef): Res =
  let resId = self.resrefIdLookup[rr]
  let bifIdx = resId shr 20
  let bifId = resId and 0xfffff

  expect(bifIdx >= 0 and bifIdx < self.bifs.len)

  let b = self.bifs[bifIdx]
  let va = b.getVariableResource(bifId)
  let st = b.getStreamForVariableResource(bifId)

  result = newRes(rr, st, va.offset, va.fileSize)

method count*(self: KeyTable): int = self.resrefIdLookup.len