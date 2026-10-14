import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

export default class extends Controller {
  static values = { projected: Array, actual: Array, currency: String };

  connect() {
    this.draw = this.draw.bind(this);
    this.observer = new ResizeObserver(this.draw);
    this.observer.observe(this.element);
  }

  disconnect() {
    this.observer?.disconnect();
  }

  draw() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;
    const projected = this.projectedValue.map((row) => ({
      date: new Date(`${row.date}T12:00:00`),
      balances: row.balances.map(Number),
    }));
    if (width < 100 || !projected.length) return;

    const margin = { top: 12, right: 10, bottom: 26, left: 52 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;
    const numberOfDebts = Math.max(
      ...projected.map((row) => row.balances.length),
    );
    const stackData = projected.map((row) => {
      const values = { date: row.date };
      for (let index = 0; index < numberOfDebts; index += 1) {
        values[index] = row.balances[index] || 0;
      }
      return values;
    });
    const stacked = d3.stack().keys(d3.range(numberOfDebts))(stackData);
    const maxTotal = d3.max(projected, (row) => d3.sum(row.balances)) || 1;
    const x = d3
      .scaleTime()
      .domain(d3.extent(projected, (row) => row.date))
      .range([0, innerWidth]);
    const y = d3
      .scaleLinear()
      .domain([0, maxTotal])
      .nice()
      .range([innerHeight, 0]);

    d3.select(this.element).selectAll("svg").remove();
    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img")
      .attr(
        "aria-label",
        this.element.previousElementSibling?.textContent ||
          "Projected debt balances",
      );
    const chart = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);
    const colors = [
      "var(--color-info)",
      "var(--color-success)",
      "var(--color-warning)",
      "var(--color-link)",
    ];
    const area = d3
      .area()
      .x((point) => x(point.data.date))
      .y0((point) => y(point[0]))
      .y1((point) => y(point[1]));
    chart
      .selectAll("path.debt")
      .data(stacked)
      .join("path")
      .attr("class", "debt")
      .attr("d", area)
      .attr("fill", (_, index) => colors[index % colors.length])
      .attr("opacity", (_, index) => 0.75 - (index % colors.length) * 0.08);

    const actual = this.actualValue.map((row) => ({
      date: new Date(`${row.date}T12:00:00`),
      balance: Number(row.balance),
    }));
    if (actual.length > 1) {
      chart
        .append("path")
        .datum(actual)
        .attr("fill", "none")
        .attr("stroke", "var(--color-destructive)")
        .attr("stroke-width", 2)
        .attr(
          "d",
          d3
            .line()
            .x((row) => x(row.date))
            .y((row) => y(row.balance)),
        );
    }

    chart
      .append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x).ticks(4).tickSizeOuter(0))
      .selectAll("text")
      .attr("fill", "var(--color-gray)");
    chart
      .append("g")
      .call(d3.axisLeft(y).ticks(4).tickFormat(d3.format("~s")))
      .selectAll("text")
      .attr("fill", "var(--color-gray)");
    chart
      .selectAll(".domain,.tick line")
      .attr("stroke", "var(--color-tertiary)");
  }
}
