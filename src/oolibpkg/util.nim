{.experimental: "strictFuncs".}
import macros
import tmpl


type
  ClassKind* = enum
    Normal
    Inheritance
    Distinct
    Alias

  ClassStatus* = tuple
    isPub, isOpen: bool
    kind: ClassKind
    name, base: NimNode

  ConstructorStatus* = tuple
    hasConstructor: bool
    node: NimNode


using
  node, constructor, theProc, typeName, baseName: NimNode
  status: ClassStatus
  isPub: bool


func newClassStatus(
    isPub,
    isOpen = false;
    kind = Normal;
    name: NimNode;
    base: NimNode = nil
): ClassStatus =
  (
    isPub: isPub,
    isOpen: isOpen,
    kind: kind,
    name: name,
    base: base
  )


func isDistinct(node): bool {.compileTime.} =
  node.kind == nnkCall and node[1].kind == nnkDistinctTy


func isPub(node): bool {.compileTime.} =
  node.kind == nnkCommand and node[0].eqIdent"pub"


func isOpen(node): bool {.compileTime.} =
  node.kind == nnkPragmaExpr and node[1][0].eqIdent"open"


func isInheritance(node): bool {.compileTime.} =
  node.kind == nnkInfix and node[0].eqIdent"of"


func isSuperFunc(node): bool {.compileTime.} =
  ## Returns whether struct is `super.f()` or not.
  node.kind == nnkCall and
  node[0].kind == nnkDotExpr and
  node[0][0].eqIdent"super"


func hasAsterisk(node): bool {.compileTime.} =
  node.len > 0 and
  node.kind == nnkPostfix and
  node[0].eqIdent"*"


func isConstructor*(node): bool {.compileTime.} =
  node[0].kind == nnkAccQuoted and node.name.eqIdent"new"


func isEmpty*(node): bool {.compileTime.} =
  node.kind == nnkEmpty


proc updateStatus*(cStatus: var ConstructorStatus; node) {.compileTime.} =
  if node.isConstructor:
    if cStatus.hasConstructor: error "Constructor already exists", node
    cStatus.hasConstructor = true
    cStatus.node = node


func insertIn1st*(node; inserted: NimNode) {.compileTime.} =
  node.insert 1, inserted


func insertSelf*(
    theProc: NimNode{nkProcDef};
    typeName
): NimNode {.compileTime.} =
  ## Inserts `self: typeName` in the 1st of theProc.params.
  result = theProc
  result.params.insertIn1st newIdentDefs(ident "self", typeName)


proc replaceSuper*(node): NimNode =
  ## Replaces `super.f()` with `procCall Base(self).f()`.
  result = node
  if node.isSuperFunc:
    result = newTree(
      nnkCommand,
      ident "procCall",
      copyNimTree(node)
    )
    return
  for i, n in node:
    result[i] = n.replaceSuper()


func newSuperStmt(baseName): NimNode {.compileTime.} =
  ## Generates `var super = Base(self)`.
  newVarStmt ident"super", newCall(baseName, ident "self")


func insertSuperStmt*(
    theProc: NimNode{nkProcDef};
    baseName
): NimNode {.compileTime.} =
  ## Inserts `var super = Base(self)` in the 1st line of `theProc.body`.
  result = theProc
  result.body.insert 0, newSuperStmt(baseName)


func delDefaultValue*(node): NimNode {.compileTime.} =
  result = node
  result[^1] = newEmptyNode()


func newPostfix(node): NimNode {.compileTime.} =
  nnkPostfix.newTree ident"*", node


proc decideStatus(node; isPub): ClassStatus {.compileTime.} =
  case node.kind
  of nnkIdent:
    result = newClassStatus(
      isPub = isPub,
      name = node
    )
  of nnkCall:
    if node.isDistinct:
      return newClassStatus(
        isPub = isPub,
        kind = Distinct,
        name = node[0],
        base = node[1][0]
      )
    else:
      return newClassStatus(
        isPub = isPub,
        kind = Alias,
        name = node[0],
        base = node[1]
      )
    error "Unsupported syntax", node
  of nnkInfix:
    if node.isInheritance:
      if node[2].isOpen:
        return newClassStatus(
          isPub = isPub,
          isOpen = true,
          kind = Inheritance,
          name = node[1],
          base = node[2][0]
        )
      return newClassStatus(
        isPub = isPub,
        isOpen = true,
        kind = Inheritance,
        name = node[1],
        base = node[2]
      )
    error "Unsupported syntax", node
  of nnkPragmaExpr:
    if node.isOpen:
      result = newClassStatus(
        isPub = isPub,
        isOpen = true,
        name = node[0]
      )
      if node[0].isDistinct:
        return newClassStatus(
          isPub = isPub,
          isOpen = true,
          kind = Distinct,
          name = node[0][0],
          base = node[0][1][0]
        )
      return
    error "Unsupported pragma", node
  else:
    error "Unsupported syntax", node


proc parseHead*(head: NimNode): ClassStatus {.compileTime.} =
  case head.len
  of 0:
    result = newClassStatus(name = head)
  of 1:
    error "Unsupported syntax", head
  of 2:
    result = decideStatus(
      if head.isPub: head[1] else: head,
      head.isPub
    )
  of 3:
    if head.isInheritance:
      if head[2].isOpen:
        warning "{.open.} is ignored in a definition of subclass", head
        return newClassStatus(
          kind = Inheritance,
          name = head[1],
          base = head[2][0]
        )
      return newClassStatus(
        kind = Inheritance,
        name = head[1],
        base = head[2]
      )
    error "Unsupported syntax", head
  else:
    error "Too many arguments", head


func newSelfStmt(typeName): NimNode {.compileTime.} =
  ## Generates `var self = typeName()`.
  newVarStmt ident"self", newCall(typeName)


func newResultAsgn(rhs: string): NimNode {.compileTime.} =
  newAssignment ident"result", ident rhs


func toRecList*(s: seq[NimNode]): NimNode {.compileTime.} =
  result = nnkRecList.newNimNode()
  for def in s:
    result.add def


func rmAsterisk(node): NimNode {.compileTime.} =
  result = node
  if node.hasAsterisk:
    result = node[1]


proc rmAsteriskFromIdent*(def: NimNode): NimNode {.compileTime.} =
  result = nnkIdentDefs.newNimNode()
  for v in def[0..^3]:
    result.add v.rmAsterisk
  result.add(def[^2], def[^1])


func decomposeDefsIntoVars*(s: seq[NimNode]): seq[NimNode] {.compileTime.} =
  for def in s:
    for v in def[0..^3]:
      result.add v


proc genNewBody(typeName; vars: seq[NimNode]): NimNode {.compileTime.} =
  result = newStmtList newSelfStmt(typeName)
  for v in vars:
    result.insertIn1st getAst(asgnWith v)
  result.add newResultAsgn"self"


func replaceReturnTypeWith(
    constructor,
    typeName
): NimNode {.compileTime.} =
  result = constructor
  result.params[0] = typeName


proc insertArgs(
    constructor;
    vars: seq[NimNode]
): NimNode {.compileTime.} =
  ## Inserts `vars` to constructor args.
  result = constructor
  for v in vars[0..^1]:
    result.params.insertIn1st(v)


proc addSignatures(
    constructor;
    status;
    args: seq[NimNode]
): NimNode {.compileTime.} =
  ## Adds signatures to `constructor`.
  constructor.name =
    if status.isPub:
      newPostfix(ident "new"&status.name.strVal)
    else:
      ident "new"&status.name.strVal
  return constructor
    .replaceReturnTypeWith(status.name)
    .insertArgs(args)


func insertBody(
    constructor;
    vars: seq[NimNode]
): NimNode {.compileTime.} =
  result = constructor
  if result.body[0].kind == nnkDiscardStmt:
    return
  result.body.insert 0, newSelfStmt(result.params[0])
  for v in vars.decomposeDefsIntoVars():
    result.body.insertIn1st getAst(asgnWith v)
  result.body.add newResultAsgn"self"


proc assistWithDef*(
    constructor;
    status;
    args: seq[NimNode]
): NimNode {.compileTime.} =
  ## Adds signatures and insert body to `constructor`.
  return constructor
    .addSignatures(status, args)
    .insertBody(args)


# Because it's used in template, must be exported.
func markWithAsterisk*(theProc: NimNode{nkProcDef}): NimNode {.compileTime.} =
  result = theProc
  result.name = newPostfix(theProc.name)


func newPragmaExpr(node; pragma: string): NimNode {.compileTime.} =
  result = nnkPragmaExpr.newTree(
    node,
    nnkPragma.newTree(ident pragma)
  )


func defObj(status): NimNode {.compileTime.} =
  result = getAst defObj(status.name)
  if status.isPub:
    result[0][0] = newPostfix(result[0][0])
  if status.isOpen:
    result[0][2][0][1] = nnkOfInherit.newTree ident"RootObj"
  result[0][0] = newPragmaExpr(result[0][0], "pClass")


func defObjWithBase(status): NimNode {.compileTime.} =
  result = getAst defObjWithBase(status.name, status.base)
  if status.isPub:
    result[0][0] = newPostfix(result[0][0])
  result[0][0] = newPragmaExpr(result[0][0], "pClass")


func defDistinct(status): NimNode {.compileTime.} =
  result = getAst defDistinct(status.name, status.base)
  if status.isPub:
    result[0][0][0] = newPostfix(result[0][0][0])
  if status.isOpen:
    # replace {.final.} with {.inheritable.}
    result[0][0][1][0] = ident "inheritable"
    result[0][0][1].add ident "pClass"


func defAlias(status): NimNode {.compileTime.} =
  result = getAst defAlias(status.name, status.base)
  if status.isPub:
    result[0][0] = newPostfix(result[0][0])
  result[0][0] = newPragmaExpr(result[0][0], "pClass")


func getAstOfClassDef(status: ClassStatus): NimNode {.compileTime.} =
  result =
    case status.kind
    of Normal:
      status.defObj()
    of Inheritance:
      status.defObjWithBase()
    of Distinct:
      status.defDistinct()
    of Alias:
      status.defAlias()


func defClass*(status: ClassStatus): NimNode {.compileTime.} =
  newStmtList getAstOfClassDef(status)


template defNew*(status; args: seq[NimNode]): NimNode =
  var
    name = ident "new"&status.name.strVal
    params = status.name&args
    body = genNewBody(
      status.name,
      args.decomposeDefsIntoVars()
    )
  if status.isPub:
    newProc(name, params, body).markWithAsterisk()
  else:
    newProc(name, params, body)


proc genConstant*(className: string; node: NimNode): NimNode {.compileTime.} =
  # generate both a template for use with typedesc and a method for dynamic dispatch
  #
  # dumpAstGen:
  #   template speed*(self: typedesc[A]): untyped = 10.0f
  #   method speed*(self: A): typeof(10.0f) {.optBase.} = 10.0f

  nnkStmtList.newTree(
    # template
    nnkTemplateDef.newTree(
      node[0],
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        newIdentNode("untyped"),
        nnkIdentDefs.newTree(
          newIdentNode("self"),
          nnkBracketExpr.newTree(
            newIdentNode("typedesc"),
            newIdentNode(className)
      ),
      newEmptyNode()
    )
      ),
      newEmptyNode(),
      newEmptyNode(),
      nnkStmtList.newTree(
        node[^1]
      )
    ),
    # method
    nnkMethodDef.newTree(
      node[0],
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        node[1],
        nnkIdentDefs.newTree(
          newIdentNode("self"),
          newIdentNode(className),
          newEmptyNode(),
      )
    ),
      nnkPragma.newTree(
        newIdentNode("optBase")
      ),
      newEmptyNode(),
      nnkStmtList.newTree(
        nnkReturnStmt.newTree(
          node[^1]
        )
      )
    ),
  )
