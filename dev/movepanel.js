var n = screenCount; var out = "screens=" + n;
for (var i in panels()) { var p = panels()[i]; if (p.id == 235) { p.screen = 1; out += " panel235.screen=" + p.screen; } }
print(out);
