import re,json,collections
P = __import__('os').path.dirname(__import__('os').path.abspath(__file__)) + '/'
txt=open(P+'boards.md').read()
boards={}
cur=None
for l in txt.split('\n'):
    m=re.match(r'## Board "(.+?)"',l)
    if m: cur=m.group(1); boards[cur]=[]; continue
    m=re.match(r'(\d+)\. (.+) -> (.+)$',l)
    if m: boards[cur].append((m.group(1),m.group(2),m.group(3)))
def ov(d,s,t): return d.get((s,t))
def sel(s,t):
    o={('SelectTool.swift','Brush.swift'):2,('SelectTool.swift','Handles.swift'):2,('SelectTool.swift','Buttons.swift'):1,('SelectTool.swift','Faces.swift'):1,('SelectTool.swift','Groups.swift'):1,('SelectTool.swift','Opening.swift'):1,('SelectTool.swift','Parts.swift'):1,('SelectTool.swift','Resizing.swift'):1,('SelectTool.swift','Labels.swift'):1,
    ('Handles.swift','Resizing.swift'):2,('Handles.swift','Buttons.swift'):1,('GoingTo.swift','Opening.swift'):1,('Groups.swift','Parts.swift'):1,('Groups.swift','Stepping.swift'):1,('Parts.swift','Stepping.swift'):1,('Resizing.swift','Parts.swift'):1,('SelectionState.swift','SelectionHistory.swift'):2,('SelectionState.swift','Stepping.swift'):1,('Selection.swift','Stepping.swift'):1,('ReadableZoom','GoingTo.swift'):2,('SelectionGroups','Groups.swift'):2,('Brush.swift','SelectionState.swift'):1}
    if (s,t) in o: return o[(s,t)]
    if s=='SelectionPlugin': return 0
    if not s.endswith('.swift') and t.endswith('.swift'): return 2 if t!='Selection.swift' else 1
    return 0
def men(s,t):
    o={('MentionTextView.swift','MentionPicker.swift'):2,('MentionTextView.swift','MentionPill.swift'):2,('MentionTextView.swift','MentionPlaces.swift'):1,('MentionTextView.swift','MentionText.swift'):1,('MentionTextView.swift','MentionTextStyle.swift'):1,
    ('MentionState.swift','MentionCatalog.swift'):2,('MentionState.swift','MentionLabels.swift'):1,('MentionState.swift','MentionEdges.swift'):1,('MentionState.swift','MentionMatching.swift'):1,('MentionState.swift','MentionQuote.swift'):1,('MentionState.swift','MentionText.swift'):1,('MentionState.swift','MentionScope.swift'):0,
    ('MentionChoices.swift','MentionPlaces.swift'):2,('MentionChoices.swift','MentionState.swift'):1,('MentionPicker.swift','MentionPlaces.swift'):1,('MentionPicker.swift','MentionState.swift'):1,
    ('Mentions.swift','MentionEdges.swift'):1,('Mentions.swift','MentionFaces.swift'):1,('Mentions.swift','MentionParts.swift'):1,('Mentions.swift','MentionState.swift'):1,
    ('MentionFaces.swift','MentionDrawing.swift'):1,('MentionFaces.swift','MentionState.swift'):1,('MentionParts.swift','MentionDrawing.swift'):1,('MentionParts.swift','MentionState.swift'):1,
    ('MentionDrawing.swift','MentionPill.swift'):1,('MentionDrawing.swift','MentionText.swift'):1,('MentionDrawing.swift','MentionTextStyle.swift'):1,
    ('MentionLights.swift','MentionEdges.swift'):2,('MentionQueries.swift','MentionEdges.swift'):2,('MentionQueries.swift','MentionLabels.swift'):1,('MentionQueries.swift','MentionState.swift'):1,('MentionQueries.swift','MentionText.swift'):0,
    ('MentionValidation.swift','MentionProblems.swift'):2,('MentionLayouts','MentionLayout.swift'):2,('MentionLayout.swift','MentionText.swift'):1,('MentionLayout.swift','MentionState.swift'):1,
    ('MentionTexts','MentionDrawing.swift'):1,('ShapeMentions','Mentionable.swift'):2,('MentionScopeJoins','MentionScope.swift'):2,('MentionScopes','MentionScope.swift'):2,
    ('MentionTextArea.swift','MentionTextView.swift'):2,('MentionTextArea.swift','MentionText.swift'):1,('MentionSlashBar.swift','MentionTextView.swift'):1,('MentionRows.swift','MentionText.swift'):1,('MentionQuote.swift','MentionText.swift'):1,('MentionEdges.swift','MentionText.swift'):1,
    ('MentionStyle.swift','MentionTextStyle.swift'):1,('MentionText.swift','MentionScope.swift'):1,('MentionTexts.swift','MentionMentionable'):0,('MentionTexts.swift','Mentionable.swift'):1,
    ('MentionCatalog.swift','Mentionable.swift'):1,('MentionLabels.swift','Mentionable.swift'):1,('MentionProblems.swift','Mentionable.swift'):1,('MentionProblems.swift','MentionScope.swift'):1,('MentionPicker.swift','MentionScope.swift'):1,('MentionTextArea.swift','MentionScope.swift'):0,('MentionMenus.swift','MentionState.swift'):0,
    ('MentionFind.swift','MentionDrawing.swift'):1,('MentionFind.swift','MentionState.swift'):1,('MentionFind.swift','MentionText.swift'):1,('MentionPill.swift','MentionTextStyle.swift'):1,('MentionTextStyle.swift','MentionText.swift'):1,('MentionTextView.swift','MentionScope.swift'):0}
    if (s,t) in o: return o[(s,t)]
    if s=='MentionsPlugin': return 2 if t=='Mentions.swift' else 0
    if s.endswith('Plugin'): return 1
    return 0
def draw(s,t):
    o={('Draw.swift','DrawLayout.swift'):2,('Draw.swift','DrawCommit.swift'):2,('Draw.swift','Drawing.swift'):1,('Draw.swift','DrawBoard.swift'):1,('Draw.swift','Surroundings.swift'):1,
    ('DrawCommit.swift','DrawBrought.swift'):1,('DrawCommit.swift','DrawGroups.swift'):1,('DrawCommit.swift','DrawLayout.swift'):2,('DrawCommit.swift','DrawStandIns.swift'):1,('DrawCommit.swift','StandInRoute.swift'):1,('DrawCommit.swift','Drawing.swift'):1,
    ('DrawLayout.swift','DrawObstacles.swift'):2,('DrawLayout.swift','DrawStandIns.swift'):1,('DrawLayout.swift','Drawing.swift'):1,
    ('DrawBoard.swift','DrawIDs.swift'):1,('DrawBoard.swift','DrawPaths.swift'):1,('DrawBoard.swift','DrawStandIns.swift'):1,('DrawBoard.swift','Drawing.swift'):1,
    ('DrawStandIns.swift','StandInRoute.swift'):2,('StandInRoute.swift','Surroundings.swift'):1,('Drawing.swift','Kinds.swift'):1,('DrawQueries.swift','DrawVocabulary.swift'):1,
    ('DrawBrought.swift','DrawLayout.swift'):1,('DrawIDs.swift','DrawStandIns.swift'):1,('DrawPaths.swift','DrawStandIns.swift'):1,('DrawGroups.swift','DrawLayout.swift'):1,('DrawGroups.swift','Drawing.swift'):1,('Measure.swift','DrawBoard.swift'):1,('Measure.swift','Drawing.swift'):1,('DrawEngines','Draw.swift'):1,('DrawPlugin','Draw.swift'):2,('DrawTexts.swift','Drawing.swift'):1,('DrawVocabulary.swift','Drawing.swift'):1,('DrawLayout.swift','DrawPaths.swift'):0}
    if (s,t) in o: return o[(s,t)]
    if s=='DrawPlugin': return 0
    if t=='DrawPoints.swift' and not s.endswith('.swift'): return 1
    return 0
def mod(s,t):
    o={('CanvasDocument.swift','ShapeStack.swift'):2,('CanvasDocument.swift','StackingKey.swift'):1,('CanvasDocument.swift','ShapeRecord.swift'):1,
    ('CanvasFile.swift','BoardID.swift'):2,('CanvasFile.swift','CanvasDocument.swift'):2,('CanvasFile.swift','ChangeSet.swift'):1,('CanvasFile.swift','DocumentDelta.swift'):1,('CanvasFile.swift','FileProperty.swift'):1,
    ('ChangeSet.swift','BoardID.swift'):1,('ChangeSet.swift','CanvasDocument.swift'):1,('ChangeSet.swift','ShapeRecord.swift'):1,
    ('Containment.swift','CanvasDocument.swift'):1,('Containment.swift','CanvasFile.swift'):1,('Containment.swift','ShapeRecord.swift'):1,
    ('DocumentDelta.swift','AddedProperty.swift'):1,('DocumentDelta.swift','ChangeSet.swift'):2,('DocumentDelta.swift','FileProperty.swift'):1,('DocumentDelta.swift','ShapeRecord.swift'):1,
    ('Enclosing.swift','Containment.swift'):2,('Enclosing.swift','Settling.swift'):2,('Enclosing.swift','Transaction.swift'):1,
    ('FileProperty.swift','AddedProperty.swift'):1,('Settling.swift','Containment.swift'):2,('Settling.swift','Transaction.swift'):1,
    ('ShapeNaming.swift','AddedProperty.swift'):1,('ShapeNaming.swift','ShapeRecord.swift'):1,('ShapeRecord.swift','ShapeMeta.swift'):2,('ShapeRecord.swift','StackingKey.swift'):1,
    ('ShapeStack.swift','ShapeMap.swift'):2,('ShapeStack.swift','ShapeRecord.swift'):1,('StackReplay.swift','ShapeStack.swift'):2,('StackReplay.swift','StackingKey.swift'):1,
    ('Transaction.swift','CanvasDocument.swift'):1,('Transaction.swift','CanvasFile.swift'):1,('Transaction.swift','ChangeSet.swift'):1,('Transaction.swift','StackReplay.swift'):1,('AddedProperty.swift','ShapeRecord.swift'):1}
    return o.get((s,t),0)
def ref(s,t):
    ones={(2,'3'),}
    L={3:1,6:1,9:1,11:1,15:1,16:2,17:1,18:1,19:1,20:1,22:1,24:2,29:1,30:1,31:1,32:1,33:2,37:1,40:1,42:1,44:1,46:1,49:1,51:1,53:1,54:1,55:1,57:2,58:1,60:1,62:1,64:1,67:1,68:2,70:2,71:1}
    return None
labs={}
f={'Selection':sel,'Mentions':men,'Draw':draw,'Canvas/Model':mod}
for b,ls in boards.items():
    if b=='References':
        L={3:1,6:1,9:1,11:1,15:1,16:2,17:1,18:1,19:1,20:1,22:1,24:2,29:1,30:1,31:1,32:1,33:2,37:1,40:1,42:1,44:1,46:1,49:1,51:1,53:1,54:1,55:1,57:2,58:1,60:1,62:1,64:1,67:1,68:2,70:2,71:1}
        labs[b]={n:L.get(int(n),0) for n,s,t in ls}
    else:
        labs[b]={n:f[b](s,t) for n,s,t in ls}
json.dump(labs,open(P+'labels-b.json','w'))
for b,d in labs.items():
    c=collections.Counter(d.values()); print(b,len(d),c[0],c[1],c[2])
