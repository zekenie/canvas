import json
def mk(n, twos, ones):
    d={str(i):0 for i in range(1,n+1)}
    for i in ones: d[str(i)]=1
    for i in twos: d[str(i)]=2
    return d
def L(s): return [int(x) for x in s.split()]
sel=mk(88,L("4 37 48 64 68 69 70 72 76 80 81 82 83 84 23"),
 L("5 6 7 49 85 17 21 22 34 40 47 66 71 73 74 75 45 78"))
men=mk(123,L("26 36 61 80 110 122 32 73 74 123 82 7 33 45 47 56 69 88 90 91 93 105 109 114 115 121"),
 L("4 6 8 9 12 13 16 18 19 20 21 23 25 30 31 37 40 41 43 46 51 52 54 55 57 59 62 63 64 65 66 67 68 76 79 89 92 96 97 99 100 104 112 116 119 120"))
dr=mk(97,L("59 31 23 49 50 77"),
 L("18 29 30 38 48 54 74 78 84 1 2 3 4 8 9 11 19 20 21 26 28 34 35 44 46 47 53 56 58 70 71 73 83 85 87 88 89 92 97"))
cm=mk(78,L("7 9 10 24 31 36 38 41 47 51 58 59 61 65 69 71"),
 L("2 4 6 8 11 12 13 17 18 19 21 22 25 27 29 32 34 35 42 46 54 56 62 66 67 70 72 73 75 76 78"))
rf=mk(73,L("6 11 24 30 33 40 57 68 70"),
 L("3 9 15 16 17 18 19 22 29 31 32 37 42 44 46 48 49 51 53 54 55 58 60 62 64 65 67"))
out={"Selection":sel,"Mentions":men,"Draw":dr,"Canvas/Model":cm,"References":rf}
json.dump(out,open(__import__("os").path.join(__import__("os").path.dirname(__file__), "labels-a.json"),"w"))
for k,v in out.items():
    c=[list(v.values()).count(x) for x in (0,1,2)]
    print(k,len(v),c)
