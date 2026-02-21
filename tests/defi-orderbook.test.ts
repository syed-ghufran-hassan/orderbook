import { Cl } from "@stacks/transactions";
import { describe, expect, it, beforeEach } from "vitest";

const accounts = simnet.getAccounts();
const alice = accounts.get("wallet_1")!;
const bob = accounts.get("wallet_2")!;
const charlie = accounts.get("wallet_3")!;

// Helper function to deposit tokens
function deposit(amount: number, user: string) {
  return simnet.callPublicFn(
    "defi-orderbook",
    "deposit",
    [Cl.uint(amount)],
    user
  );
}

// Helper function to add an order
function addOrder(amount: number, user: string) {
  return simnet.callPublicFn(
    "defi-orderbook",
    "add-order",
    [Cl.uint(amount)],
    user
  );
}

// Helper function to fill an order
function fillOrder(orderId: number, fillAmount: number, user: string) {
  return simnet.callPublicFn(
    "defi-orderbook",
    "fill-order",
    [Cl.uint(orderId), Cl.uint(fillAmount)],
    user
  );
}

// Helper function to get order details
function getOrder(orderId: number) {
  return simnet.callReadOnlyFn(
    "defi-orderbook",
    "get-order",
    [Cl.uint(orderId)],
    alice
  );
}

// Helper function to get user balance
function getBalance(user: string) {
  return simnet.callReadOnlyFn(
    "defi-orderbook",
    "get-balance",
    [Cl.principal(user)],
    user
  );
}

describe("Simple Orderbook Tests", () => {
  describe("Deposit Tests", () => {
    it("allows users to deposit tokens", () => {
      const deposit1 = deposit(1000, alice);
      expect(deposit1.result).toBeOk(Cl.bool(true));
      
      const balance = getBalance(alice);
      expect(balance.result).toEqual(Cl.uint(1000));
    });

    it("allows multiple deposits from same user", () => {
      deposit(500, alice);
      const deposit2 = deposit(300, alice);
      expect(deposit2.result).toBeOk(Cl.bool(true));
      
      const balance = getBalance(alice);
      expect(balance.result).toEqual(Cl.uint(800));
    });

    it("allows different users to deposit tokens", () => {
      deposit(1000, alice);
      deposit(2000, bob);

      const aliceBalance = getBalance(alice);
      const bobBalance = getBalance(bob);

      expect(aliceBalance.result).toEqual(Cl.uint(1000));
      expect(bobBalance.result).toEqual(Cl.uint(2000));
    });

    it("returns zero balance for users with no deposits", () => {
      const balance = getBalance(charlie);
      expect(balance.result).toEqual(Cl.uint(0));
    });
  });

  describe("Add Order Tests", () => {
    beforeEach(() => {
      deposit(1000, alice);
    });

    it("allows creating an order with sufficient balance", () => {
      const order1 = addOrder(500, alice);
      expect(order1.result).toBeOk(Cl.uint(1));
      
      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(500),
          active: Cl.bool(true)
        })
      );

      const balance = getBalance(alice);
      expect(balance.result).toEqual(Cl.uint(500));
    });

    it("does not allow creating an order with insufficient balance", () => {
      const order = addOrder(2000, alice);
      expect(order.result).toBeErr(Cl.uint(102));
    });

    it("allows multiple orders from same user", () => {
      addOrder(300, alice);
      const order2 = addOrder(200, alice);
      expect(order2.result).toBeOk(Cl.uint(2));
      
      const balance = getBalance(alice);
      expect(balance.result).toEqual(Cl.uint(500));
    });

    it("increments order IDs correctly", () => {
      const order1 = addOrder(100, alice);
      expect(order1.result).toBeOk(Cl.uint(1));
      
      const order2 = addOrder(200, alice);
      expect(order2.result).toBeOk(Cl.uint(2));
      
      const order3 = addOrder(300, alice);
      expect(order3.result).toBeOk(Cl.uint(3));
    });
  });

  describe("Fill Order Tests", () => {
    beforeEach(() => {
      // Reset state by depositing fresh amounts
      deposit(1000, alice);
      deposit(500, bob);
      addOrder(300, alice);
      
      // Debug: Check initial balances
      console.log("Initial Alice balance:", getBalance(alice).result);
      console.log("Initial Bob balance:", getBalance(bob).result);
    });

    it("allows filling an order partially", () => {
      const fill = fillOrder(1, 100, bob);
      expect(fill.result).toBeOk(Cl.bool(true));

      // Debug: Check balances after fill
      console.log("After fill - Alice:", getBalance(alice).result);
      console.log("After fill - Bob:", getBalance(bob).result);

      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(200),
          active: Cl.bool(true)
        })
      );

      const makerBalance = getBalance(alice);
      // Alice should have: 1000 (initial) - 300 (locked in order) + 100 (payment) = 800
      expect(makerBalance.result).toEqual(Cl.uint(800));

      const takerBalance = getBalance(bob);
      // Bob should have: 500 (initial) - 100 (payment) = 400
      expect(takerBalance.result).toEqual(Cl.uint(400));
    });

    it("allows filling an order completely", () => {
      const fill = fillOrder(1, 300, bob);
      expect(fill.result).toBeOk(Cl.bool(true));

      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(0),
          active: Cl.bool(false)
        })
      );

      const makerBalance = getBalance(alice);
      // Alice should have: 1000 (initial) - 300 (locked) + 300 (payment) = 1000
      expect(makerBalance.result).toEqual(Cl.uint(1000));

      const takerBalance = getBalance(bob);
      // Bob should have: 500 (initial) - 300 (payment) = 200
      expect(takerBalance.result).toEqual(Cl.uint(200));
    });

    it("does not allow filling more than available", () => {
      const fill = fillOrder(1, 400, bob);
      expect(fill.result).toBeErr(Cl.uint(105));
    });

    it("does not allow filling a non-existent order", () => {
      const fill = fillOrder(999, 100, bob);
      expect(fill.result).toBeErr(Cl.uint(101));
    });

    it("does not allow filling an already filled order", () => {
      fillOrder(1, 300, bob);
      const fill2 = fillOrder(1, 50, bob);
      expect(fill2.result).toBeErr(Cl.uint(105));
    });

    it("allows multiple fills of the same order", () => {
      fillOrder(1, 100, bob);
      fillOrder(1, 100, bob);
      const fill3 = fillOrder(1, 100, bob);
      expect(fill3.result).toBeOk(Cl.bool(true));

      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(0),
          active: Cl.bool(false)
        })
      );

      const makerBalance = getBalance(alice);
      // Alice should have: 1000 (initial) - 300 (locked) + 300 (total payment) = 1000
      expect(makerBalance.result).toEqual(Cl.uint(1000));
    });

    it("allows different takers to fill the same order", () => {
      deposit(300, charlie);
      
      fillOrder(1, 100, bob);
      const fill2 = fillOrder(1, 200, charlie);
      expect(fill2.result).toBeOk(Cl.bool(true));

      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(0),
          active: Cl.bool(false)
        })
      );

      const makerBalance = getBalance(alice);
      // Alice should have: 1000 (initial) - 300 (locked) + 300 (total payment) = 1000
      expect(makerBalance.result).toEqual(Cl.uint(1000));
    });
  });

  describe("Complex Scenarios", () => {
    it("handles multiple orders and fills", () => {
      deposit(1000, alice);
      deposit(800, bob);
      deposit(600, charlie);

      addOrder(300, alice);
      addOrder(200, alice);
      addOrder(400, bob);

      const fill1 = fillOrder(1, 150, charlie);
      expect(fill1.result).toBeOk(Cl.bool(true));

      const fill2 = fillOrder(3, 200, charlie);
      expect(fill2.result).toBeOk(Cl.bool(true));

      const fill3 = fillOrder(2, 200, charlie);
      expect(fill3.result).toBeOk(Cl.bool(true));

      const order1 = getOrder(1);
      expect(order1.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(150),
          active: Cl.bool(true)
        })
      );

      const order2 = getOrder(2);
      expect(order2.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(0),
          active: Cl.bool(false)
        })
      );

      const order3 = getOrder(3);
      expect(order3.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(bob),
          amount: Cl.uint(200),
          active: Cl.bool(true)
        })
      );

      const aliceBalance = getBalance(alice);
      // Alice: 1000 - 300 - 200 + 150 + 200 = 850
      expect(aliceBalance.result).toEqual(Cl.uint(850));

      const bobBalance = getBalance(bob);
      // Bob: 800 - 400 + 200 = 600
      expect(bobBalance.result).toEqual(Cl.uint(600));

      const charlieBalance = getBalance(charlie);
      // Charlie: 600 - 150 - 200 - 200 = 50
      expect(charlieBalance.result).toEqual(Cl.uint(50));
    });

    it("prevents filling orders with insufficient taker balance", () => {
      deposit(100, alice);
      addOrder(50, alice);

      deposit(30, bob);
      const fill = fillOrder(1, 50, bob);
      expect(fill.result).toBeErr(Cl.uint(102));
    });
  });

  describe("Read-only Functions", () => {
    beforeEach(() => {
      deposit(1000, alice);
      addOrder(500, alice);
    });

    it("returns correct order details", () => {
      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(500),
          active: Cl.bool(true)
        })
      );
    });

    it("returns none for non-existent orders", () => {
      const order = getOrder(999);
      expect(order.result).toBeNone();
    });

    it("returns correct user balances", () => {
      const balance = getBalance(alice);
      expect(balance.result).toEqual(Cl.uint(500));
    });

    it("returns zero for users with no balance", () => {
      const balance = getBalance(bob);
      expect(balance.result).toEqual(Cl.uint(0));
    });
  });

  describe("Edge Cases", () => {
    it("allows creating order with zero amount", () => {
      deposit(100, alice);
      const order = addOrder(0, alice);
      expect(order.result).toBeOk(Cl.uint(1));
      
      const orderData = getOrder(1);
      expect(orderData.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(0),
          active: Cl.bool(true)
        })
      );
    });

    it("allows filling zero amount", () => {
      deposit(100, alice);
      deposit(100, bob);
      addOrder(50, alice);
      
      const fill = fillOrder(1, 0, bob);
      expect(fill.result).toBeOk(Cl.bool(true));
      
      const order = getOrder(1);
      expect(order.result).toBeSome(
        Cl.tuple({
          trader: Cl.principal(alice),
          amount: Cl.uint(50),
          active: Cl.bool(true)
        })
      );
    });

    it("handles multiple deposits correctly", () => {
      deposit(100, alice);
      deposit(200, alice);
      deposit(300, alice);
      
      const balance = getBalance(alice);
      expect(balance.result).toEqual(Cl.uint(600));
    });
  });
});