package com.esg;

public class Main {
    public String getGreeting() {
        return "ESG backend starting...";
    }

    public static void main(String[] args) {
        System.out.println(new Main().getGreeting());
    }
}