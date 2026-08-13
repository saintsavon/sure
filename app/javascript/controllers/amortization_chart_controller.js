import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  createChartTooltip,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

// Stacked area showing how each loan payment divides between interest and
// principal. The two series sum to the level payment, so the chart reads as
// one band split by the interest curve.
//
// Data from Loan#amortization_split_payload:
//   [{ date: "2025-02-15", principal: "786.89", interest: "1458.33" }, ...]
const MARGIN = { top: 8, right: 12, bottom: 24, left: 56 };

export default class extends Controller {
  static values = {
    data: Array,
    crossoverDate: String,
    today: String,
    crossoverLabel: { type: String, default: "Principal overtakes interest" },
    todayLabel: { type: String, default: "Today" },
    principalLabel: { type: String, default: "Principal" },
    interestLabel: { type: String, default: "Interest" },
  };

  connect() {
    this._draw = this._draw.bind(this);
    window.addEventListener("resize", this._draw);
    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(this._draw);
      this._observer.observe(this.element);
    } else {
      this._draw();
    }
  }

  disconnect() {
    window.removeEventListener("resize", this._draw);
    this._observer?.disconnect();
    this._tooltip?.remove();
    this._tooltip = null;
  }

  _draw() {
    const points = this.dataValue;
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    if (!points?.length || width === 0 || height === 0) return;

    d3.select(this.element).selectAll("svg").remove();

    const parse = d3.timeParse("%Y-%m-%d");
    const parsed = points.map((p) => ({
      date: parse(p.date),
      principal: Number.parseFloat(p.principal),
      interest: Number.parseFloat(p.interest),
    }));

    const innerW = width - MARGIN.left - MARGIN.right;
    const innerH = height - MARGIN.top - MARGIN.bottom;

    const x = d3
      .scaleTime()
      .domain(d3.extent(parsed, (d) => d.date))
      .range([0, innerW]);

    const y = d3
      .scaleLinear()
      .domain([0, d3.max(parsed, (d) => d.principal + d.interest)])
      .nice()
      .range([innerH, 0]);

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img");

    const g = svg
      .append("g")
      .attr("transform", `translate(${MARGIN.left},${MARGIN.top})`);

    g.append("g")
      .attr("transform", `translate(0,${innerH})`)
      .call(d3.axisBottom(x).ticks(6).tickSizeOuter(0))
      .attr("class", "text-xs text-secondary")
      .call((sel) => sel.select(".domain").remove());

    g.append("g")
      .call(
        d3
          .axisLeft(y)
          .ticks(4)
          .tickFormat((v) => d3.format("$,.0f")(v)),
      )
      .attr("class", "text-xs text-secondary")
      .call((sel) => sel.select(".domain").remove())
      .call((sel) =>
        sel
          .selectAll(".tick line")
          .attr("x2", innerW)
          .attr("stroke", "currentColor")
          .attr("stroke-opacity", 0.08),
      );

    // Interest on the bottom, principal stacked above it.
    const interestArea = d3
      .area()
      .x((d) => x(d.date))
      .y0(innerH)
      .y1((d) => y(d.interest));

    const principalArea = d3
      .area()
      .x((d) => x(d.date))
      .y0((d) => y(d.interest))
      .y1((d) => y(d.principal + d.interest));

    // Faint fills so the gridlines and axis labels stay readable underneath.
    g.append("path")
      .datum(parsed)
      .attr("fill", "var(--color-warning)")
      .attr("fill-opacity", 0.18)
      .attr("d", interestArea);

    g.append("path")
      .datum(parsed)
      .attr("fill", "var(--color-success)")
      .attr("fill-opacity", 0.13)
      .attr("d", principalArea);

    // The dividing curve carries the shape. No stroke on the top edge — it
    // traces the level payment, so it would read as a flat "principal" line.
    g.append("path")
      .datum(parsed)
      .attr("fill", "none")
      .attr("stroke", "var(--color-warning)")
      .attr("stroke-width", 2)
      .attr(
        "d",
        d3
          .line()
          .x((d) => x(d.date))
          .y((d) => y(d.interest)),
      );

    // Today first so the crossover label wins if the two nearly coincide.
    this._drawMarker(g, x, innerH, this.todayValue, this.todayLabelValue, 26);
    this._drawMarker(
      g,
      x,
      innerH,
      this.crossoverDateValue,
      this.crossoverLabelValue,
      12,
    );
    this._installTooltip(g, parsed, x, y, innerW, innerH);
  }

  // Vertical dashed rule with a label. Skipped when the date is absent or
  // falls outside the schedule's span.
  _drawMarker(g, x, innerH, isoDate, label, labelY) {
    if (!isoDate) return;

    const at = d3.timeParse("%Y-%m-%d")(isoDate);
    const [from, to] = x.domain();
    if (!at || at < from || at > to) return;

    g.append("line")
      .attr("x1", x(at))
      .attr("x2", x(at))
      .attr("y1", 0)
      .attr("y2", innerH)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.4)
      .attr("stroke-dasharray", "3 3")
      .attr("class", "text-secondary");

    g.append("text")
      .attr("x", x(at) + 6)
      .attr("y", labelY)
      .attr("class", "text-xs text-secondary")
      .attr("fill", "currentColor")
      .text(`${label} · ${at.getFullYear()}`);
  }

  _installTooltip(g, parsed, x, y, innerW, innerH) {
    this._tooltip?.remove();
    const tooltip = createChartTooltip(this.element);
    this._tooltip = tooltip;

    const dateEl = document.createElement("div");
    dateEl.className = CHART_TOOLTIP_CONTEXT_CLASSES;
    tooltip.appendChild(dateEl);

    // One row per series: swatch, label, figure.
    const row = (color) => {
      const wrap = document.createElement("div");
      wrap.className = "flex items-center gap-2";
      const swatch = document.createElement("span");
      swatch.className = "inline-block w-2 h-2 rounded-xs shrink-0";
      swatch.style.backgroundColor = color;
      const label = document.createElement("span");
      label.className = "text-xs text-secondary";
      const value = document.createElement("span");
      value.className = `${CHART_TOOLTIP_VALUE_CLASSES} ml-auto`;
      wrap.append(swatch, label, value);
      tooltip.appendChild(wrap);
      return { label, value };
    };

    const principalRow = row("var(--color-success)");
    const interestRow = row("var(--color-warning)");
    principalRow.label.textContent = this.principalLabelValue;
    interestRow.label.textContent = this.interestLabelValue;

    const rule = g
      .append("line")
      .attr("y1", 0)
      .attr("y2", innerH)
      .attr("stroke", "currentColor")
      .attr("stroke-opacity", 0.5)
      .attr("stroke-dasharray", "3 3")
      .attr("class", "text-secondary")
      .style("opacity", 0);

    const dot = g
      .append("circle")
      .attr("r", 4)
      .attr("fill", "var(--color-warning)")
      .style("opacity", 0);

    const bisect = d3.bisector((d) => d.date).center;
    const money = d3.format("$,.2f");
    const month = d3.timeFormat("%b %Y");

    g.append("rect")
      .attr("width", innerW)
      .attr("height", innerH)
      .attr("fill", "transparent")
      .on("mousemove", (event) => {
        const [mx] = d3.pointer(event);
        const d = parsed[bisect(parsed, x.invert(mx))];
        if (!d) return;

        const share = Math.round((d.interest / (d.principal + d.interest)) * 100);
        dateEl.textContent = month(d.date);
        principalRow.value.textContent = money(d.principal);
        interestRow.value.textContent = `${money(d.interest)} (${share}%)`;

        const cx = x(d.date);
        rule.attr("x1", cx).attr("x2", cx).style("opacity", 1);
        dot.attr("cx", cx).attr("cy", y(d.interest)).style("opacity", 1);

        // createChartTooltip returns the node with display:none.
        tooltip.style.display = "block";

        // Beside the crosshair, flipping left near the right edge.
        const offset = 12;
        const w = tooltip.offsetWidth;
        const flip = cx + offset + w > innerW;
        tooltip.style.left = `${
          MARGIN.left + (flip ? cx - offset - w : cx + offset)
        }px`;
        tooltip.style.top = `${MARGIN.top + innerH / 2 - tooltip.offsetHeight / 2}px`;
      })
      .on("mouseleave", () => {
        tooltip.style.display = "none";
        rule.style("opacity", 0);
        dot.style("opacity", 0);
      });
  }
}
