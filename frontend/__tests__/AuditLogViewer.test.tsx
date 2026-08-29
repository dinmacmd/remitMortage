import { filterAuditLogs, filterByDateRange, exportToCsv, AuditLogEntry } from "../lib/auditApi";

describe("auditApi", () => {
  const sampleLogs: AuditLogEntry[] = [
    {
      id: "1",
      action: "deposit",
      actorAddress: "GABC123DEF456",
      ipAddress: "192.168.1.1",
      metadata: { amount: 5000, goal: "house" },
      createdAt: "2025-01-15T10:30:00Z",
    },
    {
      id: "2",
      action: "withdraw",
      actorAddress: "GXYZ789ABC012",
      ipAddress: "192.168.1.2",
      metadata: { refund: 4750 },
      createdAt: "2025-01-16T14:00:00Z",
    },
    {
      id: "3",
      action: "loan_approved",
      actorAddress: "GABC123DEF456",
      ipAddress: null,
      metadata: { loanId: "loan-42", principal: 70000 },
      createdAt: "2025-01-17T09:15:00Z",
    },
  ];

  describe("filterAuditLogs", () => {
    it("returns all logs when search is empty", () => {
      expect(filterAuditLogs(sampleLogs, "")).toHaveLength(3);
    });

    it("filters by action name", () => {
      const result = filterAuditLogs(sampleLogs, "deposit");
      expect(result).toHaveLength(1);
      expect(result[0].action).toBe("deposit");
    });

    it("filters by actor address", () => {
      const result = filterAuditLogs(sampleLogs, "GABC123");
      expect(result).toHaveLength(2);
    });

    it("filters by metadata content", () => {
      const result = filterAuditLogs(sampleLogs, "loan-42");
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe("3");
    });

    it("is case-insensitive", () => {
      const result = filterAuditLogs(sampleLogs, "DEPOSIT");
      expect(result).toHaveLength(1);
    });

    it("returns empty for non-matching search", () => {
      expect(filterAuditLogs(sampleLogs, "nonexistent")).toHaveLength(0);
    });
  });

  describe("filterByDateRange", () => {
    it("filters by from date", () => {
      const result = filterByDateRange(sampleLogs, new Date("2025-01-16"));
      expect(result).toHaveLength(2);
      expect(result[0].id).toBe("2");
    });

    it("filters by to date", () => {
      const result = filterByDateRange(sampleLogs, undefined, new Date("2025-01-16"));
      expect(result).toHaveLength(2);
      expect(result[1].id).toBe("2");
    });

    it("filters by date range", () => {
      const result = filterByDateRange(
        sampleLogs,
        new Date("2025-01-16"),
        new Date("2025-01-16")
      );
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe("2");
    });
  });

  describe("exportToCsv", () => {
    it("generates valid CSV with headers", () => {
      const csv = exportToCsv(sampleLogs);
      const lines = csv.split("\n");
      expect(lines[0]).toBe("ID,Action,Actor Address,IP Address,Metadata,Created At");
      expect(lines).toHaveLength(4); // header + 3 rows
    });

    it("escapes CSV fields with commas", () => {
      const logsWithComma: AuditLogEntry[] = [
        {
          id: "1",
          action: "deposit",
          actorAddress: "GABC",
          ipAddress: null,
          metadata: { description: "hello, world" },
          createdAt: "2025-01-15T10:30:00Z",
        },
      ];
      const csv = exportToCsv(logsWithComma);
      expect(csv).toContain('"hello, world"');
    });

    it("returns only header for empty logs", () => {
      const csv = exportToCsv([]);
      expect(csv).toBe("ID,Action,Actor Address,IP Address,Metadata,Created At");
    });
  });
});
