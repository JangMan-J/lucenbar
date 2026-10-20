var out = [];
for (var i in panels()) { var p = panels()[i]; for (var j in p.widgetIds) { var w = p.widgetById(p.widgetIds[j]); if (w.type === "io.github.jangmanj.lucenbarlite") out.push("panel=" + p.id + " screen=" + p.screen + " location=" + p.location + " widget=" + w.id); } }
print(out.join("\n"));
