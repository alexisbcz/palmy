// A chart in the .xlsx package: three parts, not one.
//
// A spreadsheet chart is the most involved thing in SpreadsheetML, because it
// is not a spreadsheet feature at all — it is a DrawingML graphic frame that
// happens to be anchored to two cells, pointing at a chart part in a third
// namespace. So one chart costs:
//
//   /xl/charts/chartN.xml                    the chart itself (c: namespace)
//   /xl/drawings/drawingM.xml                the frame and its cell anchor
//   /xl/drawings/_rels/drawingM.xml.rels     frame -> chart
//   /xl/worksheets/_rels/sheetK.xml.rels     sheet -> drawing
//   plus a <drawing r:id> in the sheet and two Overrides in [Content_Types]
//
// This writes real chart parts rather than a picture of a chart, so the file
// opens in Excel and LibreOffice as a *chart* — selectable, with live series
// formulas that follow the cells when they change.
//
// Every series carries both its `<c:f>` formula and a cache of the values, so
// a reader that does not recalculate still draws the right picture, and one
// that does picks the formulas up.
package main

import "core:fmt"
import "core:strings"

NS_CHART :: "http://schemas.openxmlformats.org/drawingml/2006/chart"
NS_DRAWML :: "http://schemas.openxmlformats.org/drawingml/2006/main"
NS_SSDRAW :: "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"

// Axis ids are arbitrary but must be consistent between the plot and the
// axes, and distinct from each other.
CHART_CAT_AX :: 111111111
CHART_VAL_AX :: 222222222

// abs_ref renders `Sheet1!$A$2:$A$5`, which is the only form a chart
// reference is written in.
@(private = "file")
abs_ref :: proc(sheet: string, r: Rect_I) -> string {
	one := r.r0 == r.r1 && r.c0 == r.c1
	if one {
		return fmt.tprintf(
			"%s$%s$%d",
			sheet_prefix(sheet),
			col_name(r.c0),
			r.r0 + 1,
		)
	}
	return fmt.tprintf(
		"%s$%s$%d:$%s$%d",
		sheet_prefix(sheet),
		col_name(r.c0),
		r.r0 + 1,
		col_name(r.c1),
		r.r1 + 1,
	)
}

@(private = "file")
write_str_ref :: proc(b: ^strings.Builder, tag, f: string, vals: []string) {
	fmt.sbprintf(b, "<c:%s><c:strRef><c:f>%s</c:f><c:strCache>", tag, xml_escape(f))
	fmt.sbprintf(b, "<c:ptCount val=\"%d\"/>", len(vals))
	for v, i in vals {
		fmt.sbprintf(b, "<c:pt idx=\"%d\"><c:v>%s</c:v></c:pt>", i, xml_escape(v))
	}
	fmt.sbprintf(b, "</c:strCache></c:strRef></c:%s>", tag)
}

@(private = "file")
write_num_ref :: proc(b: ^strings.Builder, tag, f: string, vals: []f64, have: []bool) {
	fmt.sbprintf(b, "<c:%s><c:numRef><c:f>%s</c:f><c:numCache>", tag, xml_escape(f))
	fmt.sbprintf(b, "<c:formatCode>General</c:formatCode><c:ptCount val=\"%d\"/>", len(vals))
	for v, i in vals {
		if !have[i] {
			continue // a gap is simply absent, which is what Excel writes
		}
		fmt.sbprintf(b, "<c:pt idx=\"%d\"><c:v>%s</c:v></c:pt>", i, number_source(v))
	}
	fmt.sbprintf(b, "</c:numCache></c:numRef></c:%s>", tag)
}

// chart_part_xml renders /xl/charts/chartN.xml. `data_sheet` is the name the
// series formulas must use, which is the exported name of the sheet the data
// is on — not necessarily the sheet the chart is drawn on.
chart_part_xml :: proc(sh: ^Sheet, ch: Chart, data_sheet: string) -> string {
	d := chart_read(sh, ch)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n",
	)
	fmt.sbprintf(
		&b,
		"<c:chartSpace xmlns:c=\"%s\" xmlns:a=\"%s\" xmlns:r=\"%s\"><c:chart>",
		NS_CHART,
		NS_DRAWML,
		NS_REL,
	)
	if ch.title != "" {
		fmt.sbprintf(
			&b,
			"<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>%s</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title><c:autoTitleDeleted val=\"0\"/>",
			xml_escape(ch.title),
		)
	} else {
		strings.write_string(&b, "<c:autoTitleDeleted val=\"1\"/>")
	}
	strings.write_string(&b, "<c:plotArea><c:layout/>")

	kind_tag := "barChart"
	switch ch.kind {
	case .Bar:
		kind_tag = "barChart"
	case .Line:
		kind_tag = "lineChart"
	case .Pie:
		kind_tag = "pieChart"
	}
	fmt.sbprintf(&b, "<c:%s>", kind_tag)
	switch ch.kind {
	case .Bar:
		strings.write_string(
			&b,
			"<c:barDir val=\"col\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>",
		)
	case .Line:
		strings.write_string(&b, "<c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>")
	case .Pie:
		strings.write_string(&b, "<c:varyColors val=\"1\"/>")
	}

	// A pie plots one series; a bar or a line plots all of them.
	nser := ch.kind == .Pie ? min(len(d.series), 1) : len(d.series)
	cat_f := ""
	if d.has_cat && d.nrows > 0 {
		cat_f = abs_ref(
			data_sheet,
			{d.row0, d.rect.c0, d.row0 + d.nrows - 1, d.rect.c0},
		)
	}
	for j in 0 ..< nser {
		se := d.series[j]
		col := d.col0 + j
		fmt.sbprintf(&b, "<c:ser><c:idx val=\"%d\"/><c:order val=\"%d\"/>", j, j)
		if d.has_hdr {
			write_str_ref(
				&b,
				"tx",
				abs_ref(data_sheet, {d.rect.r0, col, d.rect.r0, col}),
				{se.name},
			)
		}
		// The series colour, spelled out. `<c:spPr>` has to come right after
		// `<c:tx>`; the schema is strict about the order and a reader that
		// validates will drop the whole series if it is anywhere else.
		if ch.kind == .Line {
			fmt.sbprintf(
				&b,
				"<c:spPr><a:ln w=\"28575\" cap=\"rnd\"><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill><a:round/></a:ln><a:effectLst/></c:spPr>",
				series_hex(j),
			)
		} else if ch.kind == .Bar {
			fmt.sbprintf(
				&b,
				"<c:spPr><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill><a:ln><a:noFill/></a:ln></c:spPr>",
				series_hex(j),
			)
		}
		// A pie has one series and many colours, so each slice carries its
		// own `<c:dPt>`.
		if ch.kind == .Pie {
			for k in 0 ..< len(se.vals) {
				fmt.sbprintf(
					&b,
					"<c:dPt><c:idx val=\"%d\"/><c:bubble3D val=\"0\"/><c:spPr><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill><a:ln w=\"19050\"><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill></a:ln></c:spPr></c:dPt>",
					k,
					series_hex(k),
				)
			}
		}
		if ch.kind == .Line {
			fmt.sbprintf(
				&b,
				"<c:marker><c:symbol val=\"circle\"/><c:size val=\"5\"/><c:spPr><a:solidFill><a:srgbClr val=\"%s\"/></a:solidFill></c:spPr></c:marker>",
				series_hex(j),
			)
		}
		if cat_f != "" {
			write_str_ref(&b, "cat", cat_f, d.cats[:])
		}
		write_num_ref(
			&b,
			"val",
			abs_ref(data_sheet, {d.row0, col, d.row0 + max(d.nrows, 1) - 1, col}),
			se.vals[:],
			se.have[:],
		)
		if ch.kind == .Line {
			strings.write_string(&b, "<c:smooth val=\"0\"/>")
		}
		strings.write_string(&b, "</c:ser>")
	}

	switch ch.kind {
	case .Bar:
		strings.write_string(&b, "<c:gapWidth val=\"60\"/>")
		fmt.sbprintf(&b, "<c:axId val=\"%d\"/><c:axId val=\"%d\"/>", CHART_CAT_AX, CHART_VAL_AX)
	case .Line:
		strings.write_string(&b, "<c:marker val=\"1\"/>")
		fmt.sbprintf(&b, "<c:axId val=\"%d\"/><c:axId val=\"%d\"/>", CHART_CAT_AX, CHART_VAL_AX)
	case .Pie:
		strings.write_string(&b, "<c:firstSliceAng val=\"0\"/>")
	}
	fmt.sbprintf(&b, "</c:%s>", kind_tag)

	if ch.kind != .Pie {
		// A category axis along the bottom and a value axis up the left, each
		// naming the other as the one it crosses. Getting these two ids
		// crossed is the usual reason a chart opens blank.
		fmt.sbprintf(
			&b,
			"<c:catAx><c:axId val=\"%d\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:crossAx val=\"%d\"/></c:catAx>",
			CHART_CAT_AX,
			CHART_VAL_AX,
		)
		fmt.sbprintf(
			&b,
			"<c:valAx><c:axId val=\"%d\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"l\"/><c:majorGridlines/><c:numFmt formatCode=\"General\" sourceLinked=\"1\"/><c:crossAx val=\"%d\"/></c:valAx>",
			CHART_VAL_AX,
			CHART_CAT_AX,
		)
	}
	strings.write_string(&b, "</c:plotArea>")
	if nser > 1 || ch.kind == .Pie {
		strings.write_string(
			&b,
			"<c:legend><c:legendPos val=\"b\"/><c:overlay val=\"0\"/></c:legend>",
		)
	}
	strings.write_string(
		&b,
		"<c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart></c:chartSpace>",
	)
	return strings.to_string(b)
}

// drawing_part_xml renders one sheet's /xl/drawings/drawingM.xml: a
// two-cell-anchored graphic frame per chart, which is how a chart knows which
// cells it sits over.
drawing_part_xml :: proc(charts: []Chart) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n",
	)
	fmt.sbprintf(&b, "<xdr:wsDr xmlns:xdr=\"%s\" xmlns:a=\"%s\">", NS_SSDRAW, NS_DRAWML)
	for ch, i in charts {
		fmt.sbprintf(
			&b,
			"<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>%d</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>%d</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>",
			ch.at.col,
			ch.at.row,
		)
		fmt.sbprintf(
			&b,
			"<xdr:to><xdr:col>%d</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>%d</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>",
			ch.at.col + max(ch.w, 1),
			ch.at.row + max(ch.h, 1),
		)
		fmt.sbprintf(
			&b,
			"<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"%d\" name=\"Chart %d\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>",
			i + 2,
			i + 1,
		)
		strings.write_string(
			&b,
			"<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm>",
		)
		fmt.sbprintf(
			&b,
			"<a:graphic><a:graphicData uri=\"%s\"><c:chart xmlns:c=\"%s\" xmlns:r=\"%s\" r:id=\"rId%d\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>",
			NS_CHART,
			NS_CHART,
			NS_REL,
			i + 1,
		)
	}
	strings.write_string(&b, "</xdr:wsDr>")
	return strings.to_string(b)
}

// drawing_rels_xml points each frame at its chart part. `first` is the number
// of the first chart part this drawing owns.
drawing_rels_xml :: proc(n, first: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n",
	)
	fmt.sbprintf(&b, "<Relationships xmlns=\"%s\">", NS_PKG_REL)
	for i in 0 ..< n {
		fmt.sbprintf(
			&b,
			"<Relationship Id=\"rId%d\" Type=\"%s/chart\" Target=\"../charts/chart%d.xml\"/>",
			i + 1,
			NS_REL_TYPE,
			first + i,
		)
	}
	strings.write_string(&b, "</Relationships>")
	return strings.to_string(b)
}

sheet_rels_xml :: proc(drawing_no: int) -> string {
	return fmt.tprintf(
		`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="%s"><Relationship Id="rId1" Type="%s/drawing" Target="../drawings/drawing%d.xml"/></Relationships>`,
		NS_PKG_REL,
		NS_REL_TYPE,
		drawing_no,
	)
}
