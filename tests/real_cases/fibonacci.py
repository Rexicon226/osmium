def fibonacci_sequence(limit):
    fib_seq = [0, 1]
    i = 1
    while i < limit:
        next_value = fib_seq[-1] + fib_seq[-2]
        fib_seq.append(next_value)
        i += 1
    return fib_seq

limit = 25
fib_seq = fibonacci_sequence(limit)
print(fib_seq)