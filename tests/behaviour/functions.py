def a():
    print(1)

def b():
    c()

def c():
    print(2)

a()
b()

def d(x):
    return x * 2

e = d(10)
print(e)